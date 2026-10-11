# frozen_string_literal: true

module Outbox
  # Writes a current-state item snapshot without manufacturing an observation
  # event. Backfill uses this to seed Web's current-state projection before
  # normal syncs begin emitting change history.
  class ItemSnapshotEmitter
    BACKFILL_DETECTED_BY = "backfill"

    def self.emit_baseline_for(item, observed_at:, backfilled_at: Time.current)
      new(item, observed_at:, backfilled_at:).emit
    end

    def initialize(item, observed_at:, backfilled_at:)
      @item = item
      @observed_at = observed_at
      @backfilled_at = backfilled_at
    end

    def emit
      return if item.options[:pretend] || !item.persisted? || item.external_id.blank?

      OutboxEntry.enqueue(record_kind: :item, payload:, **enqueue_context)
    end

    private

    attr_reader :item, :observed_at, :backfilled_at

    def payload
      published_snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        source: identity,
        provenance: { detected_by: BACKFILL_DETECTED_BY, backfilled_at: timestamp(backfilled_at) }
      )
    end

    def published_snapshot
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? timestamp(value) : value }
    end

    def enqueue_context
      {
        service_type: identity[:service_type], service_instance: identity[:service_instance],
        external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified, observed_at:
      }
    end

    def identity
      @identity ||= Outbox::SourceIdentity.for(item)
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end
  end
end
