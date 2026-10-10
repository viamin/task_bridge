# frozen_string_literal: true

module Outbox
  # Emits `mapping` rows (RDR #215) into the local outbox whenever sync
  # establishes or updates a SyncCollection membership (#219). Mapping facts
  # are published separately from item observations so TaskBridge Web can
  # track cross-system representations without diffing snapshots. Write
  # failures are isolated per member via Outbox::IsolatedWrite: one
  # member's failed row never blocks the others and never propagates into
  # the sync flow.
  class MappingEmitter
    MAPPING_TYPE = "representation_membership"
    MEMBERSHIP_ROLE = "member"

    # Internal provenance vocabulary (SyncMappingProvenance /
    # SyncCollection#mapping_confidence) mapped to the contract's enum-ish
    # values. `high` maps to `confirmed`, `medium` (title-derived matches)
    # to `inferred`, and `low` to `tentative` — the #222 clarified
    # decision resolving RDR #215's open question; backfill
    # (SyncBackfill::BaselineOutbox) additionally withholds `low` rows.
    # Unknown values pass through unchanged: version 1 consumers
    # must ignore unknown values rather than break.
    CONFIDENCE = {
      "high" => "confirmed",
      "medium" => "inferred",
      "low" => "tentative"
    }.freeze
    SOURCE = {
      "source_sync_id" => "sync_id_note",
      "title_fallback" => "title_match",
      "manual_backfill" => "manual"
    }.freeze

    def self.emit_for_members(collection, members:, observed_at: Time.current)
      Array(members).select { |member| eligible?(member) }.each do |member|
        Outbox::IsolatedWrite.call("mapping for #{member.item_key}") do
          identity = Outbox::SourceIdentity.for(member)
          OutboxEntry.enqueue(
            record_kind: :mapping,
            payload: payload(collection, member, identity, observed_at),
            **enqueue_context(identity, collection, observed_at)
          )
        end
      end
    end

    class << self
      private

      def eligible?(member)
        member.is_a?(Base::SyncItem) && member.persisted? && member.external_id.present?
      end

      def payload(collection, member, identity, observed_at)
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
          provenance: {
            method: collection.mapping_method,
            confidence: collection.mapping_confidence,
            metadata: collection.mapping_metadata
          }
        }
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
