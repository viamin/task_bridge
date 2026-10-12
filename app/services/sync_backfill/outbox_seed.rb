# frozen_string_literal: true

module SyncBackfill
  # Seeds current-state rows without manufacturing observation history.
  class OutboxSeed
    def initialize(item, summary:, dry_run:)
      @item = item
      @summary = summary
      @dry_run = dry_run
    end

    def call
      return summary.skipped_item(item, "missing_external_id") if item.external_id.blank?

      seed_snapshot
      seed_mapping if item.sync_collection
    end

    private

    attr_reader :item, :summary, :dry_run

    def seed_snapshot
      identity = Outbox::SourceIdentity.for(item)
      observed_at = item.last_observed_at || item.updated_at || item.created_at
      summary.snapshot(identity[:service_type])
      return if dry_run

      OutboxEntry.enqueue(record_kind: :item, payload: snapshot_payload(identity, observed_at),
                          service_type: identity[:service_type], service_instance: identity[:service_instance],
                          external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
                          source_updated_at: item.source_updated_at || item.last_modified, observed_at:)
    end

    def seed_mapping
      confidence = item.sync_collection.mapping_confidence
      return summary.withheld_mapping(confidence) if confidence == "low"
      return summary.skipped_mapping(confidence, "incomplete_mapping") if confidence.blank?

      summary.mapping(confidence)
      return if dry_run

      Outbox::MappingEmitter.emit_for_members(item.sync_collection, members: [item], observed_at: mapping_observed_at)
    end

    def snapshot_payload(identity, observed_at)
      item.normalized_snapshot.deep_transform_values { |value| timestamp(value) }.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        source: identity,
        provenance: { detected_by: "backfill", baseline: true, backfilled_at: timestamp(observed_at) }
      )
    end

    def mapping_observed_at
      item.sync_collection.mapping_last_observed_at || item.last_observed_at || item.updated_at || item.created_at
    end

    def timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end
  end
end
