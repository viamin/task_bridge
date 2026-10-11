# frozen_string_literal: true

module SyncBackfill
  class OutboxBaseline
    # Builds the minimum normalized item snapshot payload (RDR #215) for one
    # existing sync_item, reusing Base::SnapshotSerializer (via
    # item.normalized_snapshot) for field derivation so the baseline never
    # drifts from the live change-detection snapshot shape. The baseline is
    # explicitly marked as backfill-originated (`provenance.detected_by` +
    # `backfilled_at`) rather than left to look like a live discovery event.
    class ItemSnapshotPayload
      def self.call(item, identity, observed_at)
        new(item, identity, observed_at).call
      end

      def initialize(item, identity, observed_at)
        @item = item
        @identity = identity
        @observed_at = observed_at
        @snapshot = item.normalized_snapshot
      end

      def call
        {
          contract_version: OutboxEntry::PAYLOAD_VERSION,
          item_key: item.item_key,
          entity_type: snapshot[:entity_type],
          observed_at: iso(observed_at),
          title: snapshot[:title],
          status: snapshot[:status],
          is_deleted: snapshot[:is_deleted],
          completed_at: iso(snapshot[:completed_at]),
          source_created_at: iso(snapshot[:source_created_at]),
          source_updated_at: iso(snapshot[:source_updated_at]),
          due_at: iso(snapshot[:due_at]),
          started_at: iso(snapshot[:start_at]),
          tags: snapshot[:tags],
          source: identity,
          source_metadata: snapshot[:metadata],
          sync_collection: sync_collection_reference,
          provenance: { detected_by: "backfill", backfilled_at: iso(Time.current) }
        }
      end

      private

      attr_reader :item, :identity, :observed_at, :snapshot

      def sync_collection_reference
        return unless item.sync_collection_id

        { sync_collection_id: item.sync_collection_id }
      end

      def iso(time)
        time&.utc&.iso8601(6)
      end
    end
  end
end
