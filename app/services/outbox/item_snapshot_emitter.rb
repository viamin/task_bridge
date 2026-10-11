# frozen_string_literal: true

module Outbox
  # Seeds one current-state item row. It deliberately does not emit an
  # observation: a backfill is a baseline, not a historical source event.
  class ItemSnapshotEmitter
    def self.emit_baseline_for(item, observed_at:)
      new(item, observed_at:).emit_baseline
    end

    def initialize(item, observed_at:)
      @item = item
      @observed_at = observed_at
    end

    def emit_baseline
      return if item.external_id.blank?

      OutboxEntry.enqueue(record_kind: :item, payload:, **enqueue_context)
    end

    private

    attr_reader :item, :observed_at

    def payload
      serialized_snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        provenance: {
          detected_by: "backfill",
          backfilled_at: timestamp(observed_at)
        }
      )
    end

    def serialized_snapshot
      item.normalized_snapshot.except(:version).deep_transform_values do |value|
        value.respond_to?(:utc) ? timestamp(value) : value
      end
    end

    def enqueue_context
      identity = Outbox::SourceIdentity.for(item)
      identity.slice(:service_type, :service_instance, :external_id).merge(
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end
  end
end
