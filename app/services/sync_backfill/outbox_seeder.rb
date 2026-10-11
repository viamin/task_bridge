# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from existing local sync
  # data.  It intentionally creates item rows, not historical observations:
  # the local rows tell us what is true now, not when a remote change happened.
  class OutboxSeeder
    BACKFILL_DETECTED_BY = "backfill"

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = { items: Hash.new(0), mappings: Hash.new(0), skipped: Hash.new(0) }
    end

    def run!
      SourceProvenance.run! unless dry_run
      seed_items
      seed_mappings
      summary
    end

    private

    attr_reader :dry_run, :summary

    def seed_items
      Base::SyncItem.find_each do |item|
        item.external_id.present? ? seed_item(item) : skip(:missing_external_id)
      end
    end

    def seed_item(item)
      identity = Outbox::SourceIdentity.for(item)
      observed_at = observed_at_for(item)
      summary[:items][identity[:service_type]] += 1
      return if dry_run

      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, identity, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
      item.update_column(:last_snapshot, serialized_snapshot(item)) if item.last_snapshot.blank?
    end

    def seed_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence || inferred_confidence_for(collection)
        unless publishable_confidence?(confidence)
          skip(:"mapping_#{confidence.presence || 'unknown'}")
          next
        end

        members = collection.sync_items.select { |member| member.external_id.present? }
        skipped_members = collection.sync_items.size - members.size
        skipped_members.times { skip(:mapping_missing_external_id) }
        summary[:mappings][confidence] += members.size
        Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at: mapping_observed_at(collection)) unless dry_run
      end
    end

    def publishable_confidence?(confidence)
      %w[high medium].include?(confidence)
    end

    def inferred_confidence_for(collection)
      members = collection.sync_items.to_a.compact
      return "low" if members.length < 2

      SyncMappingProvenance.preferred_for(members).fetch(:confidence)
    end

    def item_payload(item, identity, observed_at)
      serialized_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        source: identity,
        provenance: { detected_by: BACKFILL_DETECTED_BY, backfilled_at: iso_timestamp(Time.current) }
      )
    end

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? iso_timestamp(value) : value }
    end

    def observed_at_for(item)
      item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end

    def skip(reason)
      summary[:skipped][reason] += 1
    end
  end
end
