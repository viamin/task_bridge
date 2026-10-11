# frozen_string_literal: true

module Outbox
  # Emits one current-state `item` row (RDR #215) into the local outbox per
  # Base::SyncItem. The baseline backfill (#222) is the producer: existing
  # synchronized data must appear in TaskBridge Web as known current state,
  # never as historical change events, so rows carry
  # `provenance.detected_by: "backfill"` and a `backfilled_at` timestamp and
  # no `snapshot_seen` observation is written for them. Row identity is
  # deterministic: the idempotency key embeds the item's stable
  # `last_observed_at`, so reruns (even after delivered rows were pruned)
  # reproduce the same key and payload instead of duplicating facts.
  # Write failures are isolated via Outbox::IsolatedWrite like the other
  # outbox producers.
  class ItemSnapshotEmitter
    DETECTED_BY = "backfill"

    def self.emit_for_item(item, observed_at: nil)
      Outbox::IsolatedWrite.call("item snapshot for #{item.item_key}") do
        new(item, observed_at:).emit
      end
    end

    def initialize(item, observed_at:)
      @item = item
      @observed_at = observed_at || item.last_observed_at || item.updated_at || item.created_at || Time.current
    end

    def emit
      return if item.options[:pretend] || !item.persisted? || item.external_id.blank?

      OutboxEntry.enqueue(record_kind: :item, payload:, **enqueue_context)
    end

    private

    attr_reader :item, :observed_at

    # The published snapshot plus contract identity and the baseline marker.
    # `backfilled_at` intentionally reuses the row's deterministic
    # `observed_at` (the item's last observation) rather than the wall-clock
    # run time: it is part of the canonical payload, which must stay
    # identical across reruns of the same fact (RDR #215 conflict rules).
    def payload
      published_snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        provenance: {
          detected_by: DETECTED_BY,
          backfilled_at: iso_timestamp(observed_at)
        }
      )
    end

    def enqueue_context
      {
        service_type: source_identity[:service_type],
        service_instance: source_identity[:service_instance],
        external_id: source_identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
    end

    # Same published form as Outbox::ObservationEmitter#published_snapshot:
    # the normalized snapshot with timestamps rendered as ISO 8601 UTC so
    # JSON round-trips keep microsecond precision and item rows agree with
    # observation rows about the item's state.
    def published_snapshot
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def source_identity
      @source_identity ||= Outbox::SourceIdentity.for(item)
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
