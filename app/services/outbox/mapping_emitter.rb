# frozen_string_literal: true

module Outbox
  # Emits `mapping` rows (RDR #215) into the local outbox whenever sync
  # establishes or updates a SyncCollection membership (#219), and for the
  # #222 baseline backfill of existing memberships. Mapping facts are
  # published separately from item observations so TaskBridge Web can track
  # cross-system representations without diffing snapshots. Write failures
  # are isolated per member via Outbox::IsolatedWrite: one member's failed
  # row never blocks the others and never propagates into the sync flow.
  class MappingEmitter
    MAPPING_TYPE = "representation_membership"
    MEMBERSHIP_ROLE = "member"

    # Internal provenance vocabulary (SyncMappingProvenance /
    # SyncCollection#mapping_confidence) mapped to the contract's enum-ish
    # values: `high` maps to `confirmed` and `medium` (title-derived) maps
    # to `inferred`. Unknown values pass through unchanged: version 1
    # consumers must ignore unknown values rather than break.
    CONFIDENCE = {
      "high" => "confirmed",
      "medium" => "inferred",
      "low" => "tentative"
    }.freeze
    SOURCE = {
      "source_sync_id" => "sync_id_note",
      "created_by_sync" => "created_by_sync",
      "title_fallback" => "title_match",
      "manual_backfill" => "manual"
    }.freeze

    # Returns the OutboxEntry rows this call enqueued (or found already
    # enqueued); members whose write was isolated after a failure contribute
    # nil entries.
    def self.emit_for_members(collection, members:, observed_at: Time.current,
                              detected_by: nil, backfilled_at: nil)
      Array(members).filter_map do |member|
        next unless eligible?(member)

        Outbox::IsolatedWrite.call("mapping for #{member.item_key}") do
          emit_for_member(collection, member, observed_at:, detected_by:, backfilled_at:)
        end
      end
    end

    # Enqueues one membership row. Public so the #222 baseline backfill can
    # publish a member with backfill provenance; the live sync flow uses
    # emit_for_members so one failing member cannot block the rest.
    def self.emit_for_member(collection, member, observed_at:, detected_by: nil, backfilled_at: nil)
      return unless eligible?(member)

      identity = Outbox::SourceIdentity.for(member)
      OutboxEntry.enqueue(
        record_kind: :mapping,
        payload: payload(collection, member, identity, observed_at,
                         provenance: provenance(collection, detected_by:, backfilled_at:)),
        **enqueue_context(identity, collection, observed_at)
      )
    end

    class << self
      private

      def eligible?(member)
        member.is_a?(Base::SyncItem) && member.persisted? && member.external_id.present?
      end

      def payload(collection, member, identity, observed_at, provenance:)
        {
          contract_version: OutboxEntry::PAYLOAD_VERSION,
          mapping_type: MAPPING_TYPE,
          observed_at: observed_at.utc.iso8601(6),
          sync_collection: {
            sync_collection_id: collection.id,
            title: collection.title
          },
          member: identity.merge(item_key: member.item_key),
          membership_role: MEMBERSHIP_ROLE,
          mapping_confidence: CONFIDENCE.fetch(collection.mapping_confidence, collection.mapping_confidence),
          mapping_source: SOURCE.fetch(collection.mapping_method, collection.mapping_method),
          provenance:
        }
      end

      def provenance(collection, detected_by:, backfilled_at:)
        {
          method: collection.mapping_method,
          confidence: collection.mapping_confidence,
          metadata: collection.mapping_metadata
        }.tap do |provenance|
          provenance[:detected_by] = detected_by if detected_by
          provenance[:backfilled_at] = backfilled_at.utc.iso8601(6) if backfilled_at
        end
      end

      def enqueue_context(identity, collection, observed_at)
        {
          service_type: identity[:service_type],
          service_instance: identity[:service_instance],
          external_id: identity[:external_id],
          sync_collection_id: collection.id,
          observed_at:
        }
      end
    end
  end
end
