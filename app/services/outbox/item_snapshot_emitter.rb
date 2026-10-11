# frozen_string_literal: true

module Outbox
  # Emits one `item` snapshot row (RDR #215, "Minimum Normalized Item
  # Snapshot Schema") for a Base::SyncItem's current state. Unlike
  # Outbox::ObservationEmitter, this never reads or advances the diff
  # baseline: it is the baseline backfill's producer (#222), which marks
  # every row with `provenance.detected_by: "backfill"` and a
  # `backfilled_at` timestamp so TaskBridge Web never mistakes existing
  # data for a just-happened change.
  class ItemSnapshotEmitter
    DETECTED_BY = "backfill"

    def self.emit_for_item(item, backfilled_at: Time.current)
      return if item.options[:pretend] || !item.persisted? || item.external_id.blank?

      Outbox::IsolatedWrite.call("item snapshot for #{item.item_key}") do
        new(item, backfilled_at:).emit
      end
    end

    def initialize(item, backfilled_at:)
      @item = item
      @backfilled_at = backfilled_at
      @observed_at = item.last_observed_at || item.updated_at || item.created_at || Time.current
    end

    def emit
      OutboxEntry.enqueue(record_kind: :item, payload:, **context)
    end

    private

    attr_reader :item, :backfilled_at, :observed_at

    def payload
      published_snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        provenance: { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(backfilled_at) }
      )
    end

    # Identical shape to item.normalized_snapshot, with timestamps rendered
    # as ISO 8601 UTC so the stored JSON payload matches what consumers
    # receive rather than Ruby's Time#to_json representation.
    def published_snapshot
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
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

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
