# frozen_string_literal: true

module Outbox
  # Writes a current-state item row without claiming that the snapshot is a
  # historical change. Used by the one-time sync-data baseline backfill.
  class ItemSnapshotEmitter
    DETECTED_BY = "backfill"

    def self.emit_for(item, observed_at:)
      new(item, observed_at:).emit
    end

    def initialize(item, observed_at:)
      @item = item
      @observed_at = observed_at
    end

    def emit
      return unless item.persisted? && item.external_id.present?

      entry = OutboxEntry.enqueue(record_kind: :item, payload:, **context)
      item.update_column(:last_snapshot, snapshot) if entry
      entry
    end

    private

    attr_reader :item, :observed_at

    def payload
      snapshot.merge(
        observed_at: timestamp(observed_at),
        provenance: { detected_by: DETECTED_BY, baseline: true, backfilled_at: timestamp(observed_at) }
      )
    end

    def snapshot
      @snapshot ||= item.normalized_snapshot.deep_transform_values { |value| timestamp(value) }
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
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end
  end
end
