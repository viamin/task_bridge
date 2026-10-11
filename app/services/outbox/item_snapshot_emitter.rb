# frozen_string_literal: true

module Outbox
  # Enqueues a current-state item snapshot. Backfill uses this without creating
  # a synthetic observation event, so historical changes are never implied.
  class ItemSnapshotEmitter
    def self.emit_for_item(item, observed_at:, detected_by:, backfilled_at: nil)
      new(item, observed_at:, detected_by:, backfilled_at:).emit
    end

    def initialize(item, observed_at:, detected_by:, backfilled_at:)
      @item = item
      @observed_at = observed_at
      @detected_by = detected_by
      @backfilled_at = backfilled_at
    end

    def emit
      return unless item.persisted? && identity[:external_id].present?

      OutboxEntry.enqueue(record_kind: :item, payload:, **enqueue_context)
    end

    private

    attr_reader :item, :observed_at, :detected_by, :backfilled_at

    def payload
      serialized_snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        provenance: {
          detected_by:,
          initial_observation: true,
          backfilled_at: timestamp(backfilled_at)
        }.compact
      )
    end

    def serialized_snapshot
      item.normalized_snapshot.deep_transform_values { |value| timestamp(value) || value }
    end

    def enqueue_context
      identity.slice(:service_type, :service_instance, :external_id).merge(
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def identity
      @identity ||= Outbox::SourceIdentity.for(item)
    end

    def timestamp(value)
      value.utc.iso8601(6) if value.respond_to?(:utc)
    end
  end
end
