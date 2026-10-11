# frozen_string_literal: true

module Outbox
  # Enqueues a current-state item snapshot without asserting a historical
  # transition. Backfill uses this to establish the initial Web projection.
  class SnapshotEmitter
    BACKFILL_DETECTED_BY = "backfill"

    def self.emit_for_backfill(item, observed_at:)
      new(item, observed_at:).emit
    end

    def initialize(item, observed_at:)
      @item = item
      @observed_at = observed_at
    end

    def emit
      return if item.external_id.blank?

      OutboxEntry.enqueue(record_kind: :item, payload:, **context)
      item.update_column(:last_snapshot, published_snapshot) unless item.options[:pretend]
    end

    private

    attr_reader :item, :observed_at

    def payload
      published_snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        item_key: [identity[:service_instance], identity[:external_id]].join(":"),
        observed_at: timestamp(observed_at),
        provenance: {
          detected_by: BACKFILL_DETECTED_BY,
          backfilled_at: timestamp(Time.current)
        }
      )
    end

    def context
      identity.slice(:service_type, :service_instance, :external_id)
              .merge(observed_at:, source_updated_at: item.source_updated_at || item.last_modified)
    end

    def identity
      @identity ||= SourceIdentity.for(item)
    end

    def published_snapshot
      @published_snapshot ||= item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? timestamp(value) : value
      end
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end
  end
end
