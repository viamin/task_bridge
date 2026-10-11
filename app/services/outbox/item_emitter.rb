# frozen_string_literal: true

module Outbox
  # Seeds a current-state item document without inventing an observation
  # event. It is used by the one-time backfill; normal source refreshes use
  # ObservationEmitter instead.
  class ItemEmitter
    BACKFILL_DETECTED_BY = "backfill"

    def self.emit_baseline_for(item, observed_at:, backfilled_at: Time.current)
      new(item, observed_at:, backfilled_at:).emit_baseline
    end

    def initialize(item, observed_at:, backfilled_at:)
      @item = item
      @observed_at = observed_at
      @backfilled_at = backfilled_at
    end

    def emit_baseline
      return unless item.persisted? && item.external_id.present?

      row = OutboxEntry.enqueue(record_kind: :item, payload:, **enqueue_context)
      seed_diff_baseline
      row
    end

    private

    attr_reader :item, :observed_at, :backfilled_at

    def payload
      serialized_snapshot.merge(
        observed_at: iso_timestamp(observed_at),
        provenance: {
          detected_by: BACKFILL_DETECTED_BY,
          baseline: true,
          backfilled_at: iso_timestamp(backfilled_at)
        }
      )
    end

    def enqueue_context
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

    def serialized_snapshot
      @serialized_snapshot ||= item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end.deep_stringify_keys
    end

    def seed_diff_baseline
      return if item.last_snapshot == serialized_snapshot

      item.update_column(:last_snapshot, serialized_snapshot)
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
