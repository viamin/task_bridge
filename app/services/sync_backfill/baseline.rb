# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state view from local sync data. These are
  # deliberately item snapshots, not historical observation events.
  class Baseline
    DETECTED_BY = "backfill"
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = empty_summary
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :dry_run, :summary

    def backfill_items
      Base::SyncItem.find_each { |item| backfill_item(item) }
    end

    def backfill_item(item)
      return skip_item(:missing_external_id) if item.external_id.blank?

      identity = Outbox::SourceIdentity.for(item)
      observed_at = item.last_observed_at || item.updated_at || item.created_at || Time.current
      increment(:items, identity[:service_type])
      return if dry_run

      snapshot = serialized_snapshot(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: snapshot.merge(
          contract_version: OutboxEntry::PAYLOAD_VERSION,
          observed_at: timestamp(observed_at),
          provenance: { detected_by: DETECTED_BY, baseline: true, backfilled_at: timestamp(observed_at) }
        ),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
      item.update_column(:last_snapshot, snapshot) if item.last_snapshot.blank?
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
    end

    def backfill_collection(collection)
      confidence = collection.mapping_confidence
      collection.sync_items.each do |member|
        if member.external_id.blank?
          increment(:skipped, :mapping_missing_external_id)
        elsif PUBLISHABLE_CONFIDENCES.exclude?(confidence)
          increment(:withheld_mappings, confidence || "incomplete")
        else
          emit_mapping(collection, member, confidence)
        end
      end
    end

    def emit_mapping(collection, member, confidence)
      increment(:mappings, confidence)
      return if dry_run

      Outbox::MappingEmitter.emit_for_members(
        collection,
        members: [member],
        observed_at: collection.mapping_last_observed_at || collection.mapping_established_at || collection.updated_at
      )
    end

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? timestamp(value) : value
      end
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end

    def skip_item(reason)
      increment(:skipped, reason)
    end

    def increment(group, key)
      summary.fetch(group)[key.to_s] += 1
    end

    def empty_summary
      {
        dry_run:,
        items: Hash.new(0),
        mappings: Hash.new(0),
        withheld_mappings: Hash.new(0),
        skipped: Hash.new(0)
      }
    end
  end
end
