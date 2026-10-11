# frozen_string_literal: true

module SyncBackfill
  # Builds the baseline `mapping` outbox row backfill (#222) enqueues for an
  # existing SyncCollection membership.
  #
  # RDR 215's "Open Questions" leaves unresolved whether backfill should
  # publish the mappings TaskBridge holds at low confidence, and defaults to
  # withholding them until the product owner decides (issue #222 clarifying
  # answer: map `high` to `confirmed` and `medium` to `inferred`; withhold
  # `low` from publication entirely, surfacing it only through the backfill
  # dry-run summary for manual cleanup or Web-side review).
  module MappingMembership
    PUBLISHABLE_CONFIDENCE = {
      "high" => "confirmed",
      "medium" => "inferred"
    }.freeze

    module_function

    # A collection SyncBackfill::SourceProvenance has not yet assigned
    # mapping provenance to -- distinct from one withheld for low confidence.
    def incomplete?(collection)
      collection.mapping_confidence.blank?
    end

    def publishable?(collection)
      PUBLISHABLE_CONFIDENCE.key?(collection.mapping_confidence)
    end

    def eligible_member?(member)
      member.is_a?(Base::SyncItem) && member.persisted? && member.external_id.present?
    end

    def observed_at_for(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
    end

    def enqueue(collection, member, identity:, backfilled_at:)
      observed_at = observed_at_for(collection)
      Outbox::IsolatedWrite.call("backfill mapping for #{member.item_key}") do
        OutboxEntry.enqueue(
          record_kind: :mapping,
          payload: payload(collection, member, identity, observed_at, backfilled_at),
          service_type: identity[:service_type],
          service_instance: identity[:service_instance],
          external_id: identity[:external_id],
          sync_collection_id: collection.id,
          observed_at:
        )
      end
    end

    def payload(collection, member, identity, observed_at, backfilled_at)
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        mapping_type: "representation_membership",
        observed_at: observed_at.utc.iso8601(6),
        sync_collection: { sync_collection_id: collection.id, title: collection.title },
        member: identity.merge(item_key: member.item_key),
        membership_role: "member",
        mapping_confidence: PUBLISHABLE_CONFIDENCE.fetch(collection.mapping_confidence),
        mapping_source: Outbox::MappingEmitter::SOURCE.fetch(collection.mapping_method, collection.mapping_method),
        provenance: {
          method: collection.mapping_method,
          confidence: collection.mapping_confidence,
          metadata: collection.mapping_metadata,
          detected_by: "backfill"
        },
        backfilled_at: backfilled_at.utc.iso8601(6)
      }
    end
  end
end
