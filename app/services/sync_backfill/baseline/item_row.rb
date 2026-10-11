# frozen_string_literal: true

require "openssl"

module SyncBackfill
  class Baseline
    # Builds one baseline `item` record (RDR #215 "Minimum Normalized Item
    # Snapshot Schema") from a persisted SyncItem's stored columns. Unlike
    # Base::SnapshotSerializer it never reads adapter external data or
    # run-scoped option state, so it is safe for DB-loaded records of every
    # STI type: notes are reduced to the keyed digest (note export has no
    # configuration surface yet), and tags — which exist only as run
    # options on loaded records — are omitted rather than fabricated.
    #
    # Baseline rows are initial observations, not historical change events:
    # provenance carries detected_by "backfill" plus the backfilled_at run
    # timestamp so consumers can tell seeded state from live history.
    class ItemRow
      def initialize(item, backfilled_at:, parent: nil, sync_collection: nil)
        @item = item
        @backfilled_at = backfilled_at
        @parent = parent
        @sync_collection = sync_collection
      end

      # The enqueue context (OutboxEntry::ENQUEUE_CONTEXT_KEYS) for the
      # baseline row. observed_at stays stable across reruns so the
      # idempotency key — which embeds it — re-finds stored rows instead
      # of duplicating them.
      def context
        {
          service_type: identity[:service_type],
          service_instance: identity[:service_instance],
          external_id: identity[:external_id],
          observed_at: observed_at,
          source_updated_at: source_updated_at
        }
      end

      def payload
        {
          contract_version: OutboxEntry::PAYLOAD_VERSION,
          item_key: item.item_key,
          entity_type: "task",
          observed_at: iso_timestamp(observed_at),
          title: item.title,
          display_title: item.friendly_title,
          status: status,
          is_deleted: false,
          completed_at: iso_timestamp(item.completed_at || item.completed_on),
          source_created_at: iso_timestamp(item.source_created_at),
          source_updated_at: iso_timestamp(source_updated_at),
          due_at: iso_timestamp(item.due_at || item.due_date),
          started_at: iso_timestamp(item.start_at || item.start_date),
          flagged: item.flagged,
          source: identity,
          provenance: provenance
        }.merge!(optional_fields)
      end

      private

      attr_reader :item, :backfilled_at, :parent, :sync_collection

      def identity
        @identity ||= Outbox::SourceIdentity.for(item)
      end

      def observed_at
        item.last_observed_at || item.first_observed_at || item.updated_at || item.created_at || backfilled_at
      end

      def source_updated_at
        item.source_updated_at || item.last_modified
      end

      # Mirrors Base::SnapshotSerializer#status; kept local because the
      # serializer also reads option state (tags) that a DB-loaded record
      # cannot supply honestly.
      def status
        return "dropped" if item.respond_to?(:dropped?) && item.dropped?
        return "completed" if item.completed?

        "open"
      end

      # Optional fields are omitted (not nulled) when unavailable: the
      # contract allows omission, and a null would wrongly suggest the
      # field was observed to be empty.
      def optional_fields
        {
          notes_digest: notes_digest,
          source_metadata: source_metadata,
          parent: parent_payload,
          sync_collection: collection_payload
        }.compact
      end

      def notes_digest
        content = item.notes_content.to_s
        OpenSSL::HMAC.hexdigest("SHA256", TaskBridge.digest_key, content) if content.present?
      end

      def source_metadata
        { item_type: item.item_type }.compact
      end

      def provenance
        {
          detected_by: "backfill",
          backfilled_at: iso_timestamp(backfilled_at)
        }
      end

      def parent_payload
        { external_id: parent[:external_id], item_key: parent[:item_key] } if parent
      end

      def collection_payload
        return unless sync_collection

        {
          sync_collection_id: sync_collection.id,
          membership_role: Outbox::MappingEmitter::MEMBERSHIP_ROLE,
          mapping_confidence: Outbox::MappingEmitter::CONFIDENCE
                              .fetch(sync_collection.mapping_confidence, sync_collection.mapping_confidence),
          mapping_source: Outbox::MappingEmitter::SOURCE
                          .fetch(sync_collection.mapping_method, sync_collection.mapping_method)
        }
      end

      def iso_timestamp(time)
        time&.utc&.iso8601(6)
      end
    end
  end
end
