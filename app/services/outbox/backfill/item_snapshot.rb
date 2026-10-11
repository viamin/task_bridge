# frozen_string_literal: true

module Outbox
  class Backfill
    # Builds the baseline `item` snapshot payload (RDR #215, "Minimum
    # Normalized Item Snapshot Schema") for one persisted sync item.
    #
    # Everything is derived from local columns: a backfill never has
    # provider payloads, so `Base::SnapshotSerializer` — whose adapter
    # `metadata` assumes an attached external record — is intentionally
    # not consulted. `notes_preview` stays omitted because per-source
    # notes export is disabled by default, and `sync_collection` stays
    # omitted because memberships are published (and confidence-gated) as
    # separate `mapping` rows.
    #
    # `observed_at` deliberately derives from the item's own observation
    # timestamps, never the wall clock: it is embedded in the idempotency
    # key, so a wall-clock value would make reruns enqueue duplicate rows
    # instead of deduping. `backfilled_at` carries the run time instead.
    # The stored payload stays immutable across reruns because
    # `OutboxEntry.enqueue` never updates an existing row.
    class ItemSnapshot
      BACKFILL_DETECTED_BY = "backfill"
      ENTITY_TYPE = "task"

      def initialize(item, identity:, backfilled_at:)
        @item = item
        @identity = identity
        @backfilled_at = backfilled_at
      end

      def observed_at
        item.last_observed_at || item.last_modified || item.updated_at
      end

      def idempotency_key
        @idempotency_key ||=
          Outbox::IdempotencyKey.for(record_kind: :item, observed_at:, **identity)
      end

      def service_type
        identity.fetch(:service_type)
      end

      def item_key
        item.item_key
      end

      def payload
        payload = {
          contract_version: OutboxEntry::PAYLOAD_VERSION,
          item_key: item.item_key,
          entity_type: ENTITY_TYPE,
          observed_at: iso_timestamp(observed_at),
          backfilled_at: iso_timestamp(backfilled_at),
          title: item.title,
          status: status,
          is_deleted: false,
          completed_at: iso_timestamp(item.completed_at || item.completed_on),
          source_created_at: iso_timestamp(item.source_created_at),
          source_updated_at: iso_timestamp(item.source_updated_at || item.last_modified),
          due_at: iso_timestamp(item.due_at || item.due_date),
          started_at: iso_timestamp(item.start_at || item.start_date),
          tags: Array(item.tags),
          source: source,
          provenance: { detected_by: BACKFILL_DETECTED_BY }
        }
        payload[:source_metadata] = { item_type: item.item_type }.compact if item.item_type.present?
        payload
      end

      def enqueue_context
        {
          service_type: identity.fetch(:service_type),
          service_instance: identity.fetch(:service_instance),
          external_id: identity.fetch(:external_id),
          source_updated_at: item.source_updated_at || item.last_modified,
          observed_at:
        }
      end

      private

      attr_reader :item, :identity, :backfilled_at

      # Mirrors Base::SnapshotSerializer#status: no current adapter
      # persists a dropped state, but the branch is kept so a future
      # adapter (e.g. OmniFocus dropped tasks) opts in identically.
      def status
        return "dropped" if item.respond_to?(:dropped?) && item.dropped?

        item.completed? ? "completed" : "open"
      end

      # The source block keeps RDR #215's optional `source_url` present
      # only when one is known from the persisted row.
      def source
        identity[:source_url].present? ? identity : identity.except(:source_url)
      end

      def iso_timestamp(time)
        time&.utc&.iso8601(6)
      end
    end
  end
end
