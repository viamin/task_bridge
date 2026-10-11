# frozen_string_literal: true

module Outbox
  class Backfill
    # Builds the baseline `mapping` payload (RDR #215, "Mapping Update
    # Schema") for one SyncCollection membership. Mirrors the live
    # Outbox::MappingEmitter row shape — sharing its confidence/method
    # vocabulary — plus the baseline markers `backfilled_at` and
    # `provenance.detected_by: "backfill"` so TaskBridge Web can tell a
    # backfilled membership fact from one a live sync established.
    #
    # `observed_at` derives from the collection's own mapping timestamps,
    # never the wall clock, so reruns rebuild the same idempotency key
    # and dedupe instead of duplicating the fact.
    class MembershipMapping
      def initialize(collection, member, identity:, backfilled_at:)
        @collection = collection
        @member = member
        @identity = identity
        @backfilled_at = backfilled_at
      end

      def observed_at
        collection.mapping_last_observed_at || collection.updated_at
      end

      def idempotency_key
        @idempotency_key ||=
          Outbox::IdempotencyKey.for(record_kind: :mapping, observed_at:, sync_collection_id: collection.id, **identity)
      end

      def item_key
        member.item_key
      end

      # The contract confidence this membership publishes as
      # (`high`->`confirmed`, `medium`->`inferred`, `low`->`tentative`);
      # the backfill only enqueues `confirmed`/`inferred` rows.
      def confidence
        MappingEmitter::CONFIDENCE.fetch(collection.mapping_confidence, collection.mapping_confidence)
      end

      def payload
        {
          contract_version: OutboxEntry::PAYLOAD_VERSION,
          mapping_type: MappingEmitter::MAPPING_TYPE,
          observed_at: iso_timestamp(observed_at),
          backfilled_at: iso_timestamp(backfilled_at),
          sync_collection: {
            sync_collection_id: collection.id,
            title: collection.title
          },
          member: identity.merge(item_key: member.item_key),
          membership_role: MappingEmitter::MEMBERSHIP_ROLE,
          mapping_confidence: confidence,
          mapping_source: MappingEmitter::SOURCE.fetch(collection.mapping_method, collection.mapping_method),
          provenance: {
            detected_by: ItemSnapshot::BACKFILL_DETECTED_BY,
            method: collection.mapping_method,
            confidence: collection.mapping_confidence,
            metadata: collection.mapping_metadata
          }
        }
      end

      def enqueue_context
        {
          service_type: identity.fetch(:service_type),
          service_instance: identity.fetch(:service_instance),
          external_id: identity.fetch(:external_id),
          sync_collection_id: collection.id,
          observed_at:
        }
      end

      private

      attr_reader :collection, :member, :identity, :backfilled_at

      def iso_timestamp(time)
        time&.utc&.iso8601(6)
      end
    end
  end
end
