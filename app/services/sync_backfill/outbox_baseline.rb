# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from local sync data. It
  # intentionally writes item snapshots, not historical observations: existing
  # rows tell us the current state but not when any past change occurred.
  class OutboxBaseline
    BACKFILL_DETECTED_BY = "backfill"

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = {
        dry_run:,
        items: { enqueued: 0, by_service: Hash.new(0), skipped: Hash.new(0) },
        mappings: { enqueued: 0, by_confidence: Hash.new(0), skipped: Hash.new(0) }
      }
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :dry_run, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary[:items][:skipped][:missing_external_id] += 1
          next
        end

        summary[:items][:enqueued] += 1
        summary[:items][:by_service][source_identity(item).fetch(:service_type)] += 1
        next if dry_run

        enqueue_item(item)
      end
    end

    def enqueue_item(item)
      observed_at = observed_at_for(item)
      snapshot = serialized_snapshot(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: snapshot.merge(
          contract_version: OutboxEntry::PAYLOAD_VERSION,
          observed_at: iso_timestamp(observed_at),
          provenance: { detected_by: BACKFILL_DETECTED_BY, backfilled_at: iso_timestamp(observed_at) }
        ),
        **source_identity(item).slice(:service_type, :service_instance, :external_id),
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
      item.update_column(:last_snapshot, snapshot)
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence
        if confidence == "low"
          summary[:mappings][:skipped][:low_confidence] += collection.sync_items.size
          next
        end
        unless %w[high medium].include?(confidence)
          summary[:mappings][:skipped][:incomplete_provenance] += collection.sync_items.size
          next
        end

        members = collection.sync_items.select { |item| item.external_id.present? }
        summary[:mappings][:enqueued] += members.size
        summary[:mappings][:by_confidence][confidence] += members.size
        Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at: mapping_observed_at_for(collection)) unless dry_run
      end
    end

    def source_identity(item)
      Outbox::SourceIdentity.for(item)
    end

    def observed_at_for(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_observed_at_for(collection)
      collection.mapping_established_at || collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
