# frozen_string_literal: true

module Outbox
  # Emits the current normalized state of an item. This is deliberately
  # separate from ObservationEmitter: a snapshot seeds current state and is
  # not evidence that a historical source transition occurred.
  class ItemSnapshotEmitter
    def self.emit_for(item, observed_at:, detected_by:, backfilled_at: nil)
      new(item, observed_at:, detected_by:, backfilled_at:).emit
    end

    def initialize(item, observed_at:, detected_by:, backfilled_at:)
      @item = item
      @observed_at = observed_at
      @detected_by = detected_by
      @backfilled_at = backfilled_at
    end

    def emit
      return unless item.persisted? && item.external_id.present?

      OutboxEntry.enqueue(record_kind: :item, payload:, **context)
    end

    private

    attr_reader :item, :observed_at, :detected_by, :backfilled_at

    def payload
      item.normalized_snapshot.deep_transform_values { |value| timestamp(value) }.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        provenance: provenance
      )
    end

    def provenance
      { detected_by: }.tap do |value|
        value[:backfilled_at] = timestamp(backfilled_at) if backfilled_at
      end
    end

    def context
      identity = Outbox::SourceIdentity.for(item)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
    end

    def timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end
  end
end
