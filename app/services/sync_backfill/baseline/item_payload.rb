# frozen_string_literal: true

module SyncBackfill
  class Baseline
    # Builds the baseline `item` record payload (RDR #215 item snapshot
    # schema) for one existing sync item. A baseline row is a current-state
    # document, not a historical change event (#222): it has no event_type,
    # no `snapshot_seen` observation is emitted for it, and it is marked
    # with backfill provenance so consumers can distinguish it from live
    # sync-run facts. Extra fields beyond the contract minimum are safe:
    # version 1 consumers must ignore unknown fields.
    class ItemPayload
      DETECTED_BY = "backfill"

      def self.for(item, identity, observed_at:, backfilled_at:)
        new(item, identity, observed_at:, backfilled_at:).build
      end

      def initialize(item, identity, observed_at:, backfilled_at:)
        @item = item
        @identity = identity
        @observed_at = observed_at
        @backfilled_at = backfilled_at
      end

      def build
        payload = {
          contract_version: OutboxEntry::PAYLOAD_VERSION,
          item_key: snapshot[:item_key],
          entity_type: snapshot.fetch(:entity_type, "task"),
          observed_at: iso_timestamp(observed_at),
          title: snapshot[:title],
          display_title: snapshot[:display_title],
          status: snapshot[:status],
          is_deleted: snapshot[:is_deleted],
          completed_at: snapshot[:completed_at],
          source_created_at: snapshot[:source_created_at],
          source_updated_at: snapshot[:source_updated_at] || iso_timestamp(item.last_modified),
          due_at: snapshot[:due_at],
          started_at: snapshot[:start_at] || snapshot[:start_date],
          flagged: snapshot[:flagged],
          priority: snapshot[:priority],
          estimated_minutes: snapshot[:estimated_minutes],
          project: snapshot[:project],
          tags: snapshot[:tags],
          assignee: snapshot[:assignee],
          notes_digest: snapshot[:notes_digest],
          parent_item_id: snapshot[:parent_item_id],
          sub_item_count: snapshot[:sub_item_count],
          sub_item_keys: snapshot[:sub_item_keys],
          source: identity,
          source_metadata: snapshot[:metadata]
        }.compact
        payload[:sync_collection] = membership_payload if publishable_membership?
        payload[:provenance] = {
          detected_by: DETECTED_BY,
          backfilled_at: iso_timestamp(backfilled_at),
          first_observed_at: iso_timestamp(item.first_observed_at)
        }
        payload
      end

      private

      attr_reader :item, :identity, :observed_at, :backfilled_at

      # The low-confidence withholding decision (#222, resolving the RDR #215
      # open question) applies to mapping facts, so the optional membership
      # block is omitted while a collection is held at low confidence rather
      # than publishing a mapping_confidence the backfill would withhold.
      def publishable_membership?
        Outbox::MappingEmitter.publishable_confidence?(item.sync_collection&.mapping_confidence)
      end

      def membership_payload
        collection = item.sync_collection
        {
          sync_collection_id: collection.id,
          membership_role: Outbox::MappingEmitter::MEMBERSHIP_ROLE,
          mapping_confidence: Outbox::MappingEmitter.contract_confidence_for(collection.mapping_confidence),
          mapping_source: Outbox::MappingEmitter.contract_source_for(collection.mapping_method)
        }
      end

      # The published snapshot form: the normalized snapshot with timestamps
      # rendered as ISO 8601 UTC so JSON round-trips keep microsecond
      # precision, identical to Outbox::ObservationEmitter's published shape.
      def snapshot
        @snapshot ||= item.normalized_snapshot.deep_transform_values do |value|
          value.respond_to?(:utc) ? iso_timestamp(value) : value
        end
      end

      def iso_timestamp(time)
        time&.utc&.iso8601(6)
      end
    end
  end
end
