# frozen_string_literal: true

module Outbox
  # Enqueues a current-state item document without inventing a historical
  # observation. Used by the one-time sync-data backfill.
  class ItemSnapshotEmitter
    BACKFILL_DETECTED_BY = "backfill"

    def self.emit_for(item, observed_at:)
      new(item, observed_at:).emit
    end

    def initialize(item, observed_at:)
      @item = item
      @observed_at = observed_at
    end

    def emit
      return if item.external_id.blank?

      entry = OutboxEntry.enqueue(record_kind: :item, payload:, **context)
      item.update_column(:last_snapshot, snapshot) if entry
      entry
    end

    private

    attr_reader :item, :observed_at

    def payload
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        baseline: true,
        provenance: {
          detected_by: BACKFILL_DETECTED_BY,
          backfilled_at: timestamp(observed_at)
        }
      )
    end

    def context
      identity.merge(
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def identity
      @identity ||= Outbox::SourceIdentity.for(item).slice(:service_type, :service_instance, :external_id)
    end

    def snapshot
      @snapshot ||= item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? timestamp(value) : value
      end
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end
  end
end
