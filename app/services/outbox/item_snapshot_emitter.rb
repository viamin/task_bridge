# frozen_string_literal: true

module Outbox
  # Creates a current-state item row for data that predates observation
  # publication. It intentionally does not create an observation: a backfill
  # establishes a baseline, not a claim about historical source activity.
  class ItemSnapshotEmitter
    BACKFILL_DETECTED_BY = "backfill"

    def self.emit_for_backfill(item, observed_at:)
      new(item, observed_at:).emit
    end

    def initialize(item, observed_at:)
      @item = item
      @observed_at = observed_at
    end

    def emit
      entry = OutboxEntry.enqueue(record_kind: :item, payload:, **context)
      item.update_column(:last_snapshot, snapshot) if entry && item.last_snapshot.blank?
      entry
    end

    private

    attr_reader :item, :observed_at

    def payload
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        idempotency_key: idempotency_key,
        observed_at: timestamp(observed_at),
        provenance: { detected_by: BACKFILL_DETECTED_BY, backfilled_at: timestamp(observed_at) }
      )
    end

    def snapshot
      @snapshot ||= item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? timestamp(value) : value
      end
    end

    def context
      identity.slice(:service_type, :service_instance, :external_id).merge(observed_at:)
    end

    def identity
      @identity ||= Outbox::SourceIdentity.for(item)
    end

    def idempotency_key
      @idempotency_key ||= Outbox::IdempotencyKey.for(record_kind: :item, **context)
    end

    def timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
