# frozen_string_literal: true

module SyncBackfill
  class Baseline
    # Builds the RDR #215 `item` snapshot payload for one existing sync
    # item. Baseline rows are current-state documents, not historical
    # change events: provenance marks them `detected_by: "backfill"` with
    # the run's `backfilled_at` timestamp (plus the item's
    # first-observed time) so TaskBridge Web can tell them apart from
    # later live observations. Field values come from the shared
    # normalized snapshot, so baseline and live rows always agree.
    class ItemPayload
      DETECTED_BY = "backfill"

      def self.for(item, identity:, observed_at:, backfilled_at:, collection_facts: {})
        new(item, identity:, observed_at:, backfilled_at:, collection_facts:).build
      end

      def initialize(item, identity:, observed_at:, backfilled_at:, collection_facts:)
        @item = item
        @identity = identity
        @observed_at = observed_at
        @backfilled_at = backfilled_at
        @collection_facts = collection_facts
      end

      def build
        snapshot = published_snapshot
        {
          "contract_version" => OutboxEntry::PAYLOAD_VERSION,
          "item_key" => snapshot["item_key"],
          "entity_type" => snapshot["entity_type"],
          "observed_at" => iso(@observed_at),
          "title" => snapshot["title"],
          "display_title" => snapshot["display_title"],
          "status" => snapshot["status"],
          "is_deleted" => snapshot.fetch("is_deleted", false),
          "completed_at" => snapshot["completed_at"],
          "source_created_at" => snapshot["source_created_at"],
          "source_updated_at" => snapshot["source_updated_at"],
          "due_at" => snapshot["due_at"],
          "due_date" => snapshot["due_date"],
          "start_at" => snapshot["start_at"],
          "start_date" => snapshot["start_date"],
          "flagged" => snapshot["flagged"],
          "priority" => snapshot["priority"],
          "estimated_minutes" => snapshot["estimated_minutes"],
          "tags" => snapshot["tags"],
          "notes_digest" => snapshot["notes_digest"],
          "parent_item_id" => snapshot["parent_item_id"],
          "sub_item_count" => snapshot["sub_item_count"],
          "sub_item_keys" => snapshot["sub_item_keys"],
          "source" => @identity,
          "source_metadata" => snapshot["metadata"],
          "provenance" => provenance
        }.merge(sync_collection)
      end

      private

      def provenance
        {
          "detected_by" => DETECTED_BY,
          "backfilled_at" => iso(@backfilled_at),
          "first_observed_at" => iso(@item.first_observed_at || @observed_at)
        }
      end

      def sync_collection
        return {} if @item.sync_collection_id.blank?

        facts = @collection_facts[@item.sync_collection_id] || {}
        {
          "sync_collection" => {
            "sync_collection_id" => @item.sync_collection_id,
            "membership_role" => Outbox::MappingEmitter::MEMBERSHIP_ROLE,
            "mapping_confidence" => facts[:published_confidence],
            "mapping_source" => facts[:published_source]
          }
        }
      end

      # The published form of the normalized snapshot: timestamps
      # rendered as ISO 8601 UTC so JSON round-trips keep microsecond
      # precision (same treatment as Outbox::ObservationEmitter).
      def published_snapshot
        @published_snapshot ||= @item.normalized_snapshot.deep_transform_values do |value|
          value.respond_to?(:utc) ? value.utc.iso8601(6) : value
        end.deep_stringify_keys
      end

      def iso(time)
        time&.utc&.iso8601(6)
      end
    end
  end
end
