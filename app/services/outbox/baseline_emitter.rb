# frozen_string_literal: true

module Outbox
  # Seeds a current-state item row for data that predates live observation.
  # This is deliberately an item snapshot, not a snapshot_seen observation:
  # backfill establishes a baseline and must not invent historical events.
  class BaselineEmitter
    def self.emit_for(item, observed_at:)
      return unless eligible?(item)

      identity = SourceIdentity.for(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: payload(item, identity, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def self.eligible?(item)
      item.is_a?(Base::SyncItem) && item.persisted? && item.external_id.present?
    end

    def self.payload(item, identity, observed_at)
      item.normalized_snapshot.deep_transform_values { |value| timestamp(value) }.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        source: identity,
        provenance: {
          detected_by: "backfill",
          baseline: true,
          backfilled_at: timestamp(observed_at)
        }
      )
    end

    def self.timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end

    private_class_method :timestamp
  end
end
