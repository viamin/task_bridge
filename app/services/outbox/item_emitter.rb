# frozen_string_literal: true

module Outbox
  # Emits a current-state item snapshot. Backfill uses this without creating a
  # synthetic observation event: the row describes what exists now, not a
  # historical change.
  class ItemEmitter
    def self.emit_baseline(item, observed_at:, backfilled_at: Time.current)
      new(item, observed_at:, backfilled_at:).emit_baseline
    end

    def initialize(item, observed_at:, backfilled_at:)
      @item = item
      @observed_at = observed_at
      @backfilled_at = backfilled_at
    end

    def emit_baseline
      return unless item.persisted? && item.external_id.present?

      OutboxEntry.enqueue(record_kind: :item, payload:, **context)
    end

    private

    attr_reader :item, :observed_at, :backfilled_at

    def payload
      serialized_snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        provenance: { detected_by: "backfill", backfilled_at: timestamp(backfilled_at) }
      )
    end

    def serialized_snapshot
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? timestamp(value) : value }
    end

    def context
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
