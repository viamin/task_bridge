# frozen_string_literal: true

module Outbox
  # Emits `mapping` rows (RDR #215) into the local outbox whenever sync
  # establishes or updates a SyncCollection membership (#219). Mapping facts
  # are published separately from item observations so TaskBridge Web can
  # track cross-system representations without diffing snapshots. Write
  # failures are isolated per member via Outbox::IsolatedWrite: one
  # member's failed row never blocks the others and never propagates into
  # the sync flow. Returns the rows that were written (or found already
  # enqueued), so callers such as the baseline backfill (#222) can count
  # what actually landed; dropped writes are absent from the result.
  class MappingEmitter
    MAPPING_TYPE = "representation_membership"
    MEMBERSHIP_ROLE = "member"

    # Internal provenance vocabulary (SyncMappingProvenance /
    # SyncCollection#mapping_confidence) mapped to the contract's enum-ish
    # values. Unknown values pass through unchanged: version 1 consumers
    # must ignore unknown values rather than break. `medium` maps to
    # `inferred` (title-derived evidence) per the #222 clarification of
    # RDR #215's open question; `low` stays `tentative`, which the baseline
    # backfill withholds from publication entirely.
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

    def self.emit_for_members(collection, members:, observed_at: Time.current, provenance_extras: {})
      Array(members).select { |member| eligible?(member) }.filter_map do |member|
        Outbox::IsolatedWrite.call("mapping for #{member.item_key}") do
          identity = Outbox::SourceIdentity.for(member)
          OutboxEntry.enqueue(
            record_kind: :mapping,
            payload: payload(collection, member, identity, observed_at, provenance_extras:),
            **enqueue_context(identity, collection, observed_at)
          )
        end
      end
    end

    # The contract confidence for a collection's current mapping evidence.
    # Shared with the baseline backfill (#222) so it withholds exactly the
    # rows this emitter would publish as `tentative`.
    def self.translated_confidence(collection)
      CONFIDENCE.fetch(collection.mapping_confidence, collection.mapping_confidence)
    end

    class << self
      private

      def eligible?(member)
        member.is_a?(Base::SyncItem) && member.persisted? && member.external_id.present?
      end

      # `provenance_extras` lets a caller mark how the mapping row was
      # produced (e.g. the backfill's detected_by/backfilled_at) without
      # changing the shape live emitters publish.
      def payload(collection, member, identity, observed_at, provenance_extras: {})
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
          mapping_confidence: translated_confidence(collection),
          mapping_source: SOURCE.fetch(collection.mapping_method, collection.mapping_method),
          provenance: {
            method: collection.mapping_method,
            confidence: collection.mapping_confidence,
            metadata: collection.mapping_metadata
          }.merge(provenance_extras)
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
