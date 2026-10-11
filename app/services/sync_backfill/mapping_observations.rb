# frozen_string_literal: true

module SyncBackfill
  # Emits standalone `mapping` rows (RDR #215 "Mapping Update Schema") for
  # existing SyncCollection memberships that already carry confirmed or
  # inferred provenance (#222). Low-confidence memberships — collections
  # TaskBridge only matched by `manual_backfill` (no evidence at all) —
  # are withheld from publication entirely: they are counted in the
  # backfill summary for manual cleanup or later Web-side review, but no
  # OutboxEntry row is created for them, per the resolved #222
  # clarification of RDR #215's open question ("Low-confidence mapping
  # backfill policy"). This mirrors Outbox::MappingEmitter's payload shape
  # but intentionally uses a different, stricter confidence mapping and
  # eligibility rule, so it does not reuse that class directly.
  #
  # Idempotent by construction: the idempotency key derives from the
  # collection's already-recorded `mapping_last_observed_at` (or another
  # stable timestamp), never from the time the backfill happens to run.
  #
  # Run SyncBackfill::SourceProvenance first so `mapping_method` and
  # `mapping_confidence` are populated.
  class MappingObservations
    MAPPING_TYPE = Outbox::MappingEmitter::MAPPING_TYPE
    MEMBERSHIP_ROLE = Outbox::MappingEmitter::MEMBERSHIP_ROLE
    SOURCE = Outbox::MappingEmitter::SOURCE
    # Only confidences the #222 clarification allows backfill to publish.
    # "low" and blank/unknown confidence have no entry, which is the
    # withhold signal `process` checks for.
    CONFIDENCE = {
      "high" => "confirmed",
      "medium" => "inferred"
    }.freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run: false)
      @dry_run = dry_run
      @enqueued = 0
      @by_service = Hash.new(0)
      @by_confidence = Hash.new(0)
      @skipped = Hash.new(0)
    end

    def run!
      SyncCollection.includes(:sync_items).find_each { |collection| process(collection) }
      report
    end

    private

    attr_reader :dry_run

    def process(collection)
      members = eligible_members(collection)
      return @skipped["insufficient_members"] += 1 if members.length < 2

      confidence = CONFIDENCE[collection.mapping_confidence]
      return @skipped["low_confidence_withheld"] += 1 if confidence.nil?

      observed_at = observed_at_for(collection)
      members.each { |member| process_member(collection, member, confidence, observed_at) }
    end

    def process_member(collection, member, confidence, observed_at)
      identity = Outbox::SourceIdentity.for(member)
      @by_service[identity[:service_type]] += 1
      @by_confidence[collection.mapping_confidence] += 1
      @enqueued += 1
      enqueue(collection, member, identity, confidence, observed_at) unless dry_run
    end

    def eligible_members(collection)
      collection.sync_items.select { |member| member.persisted? && member.external_id.present? }
    end

    def observed_at_for(collection)
      collection.mapping_last_observed_at || collection.mapping_established_at ||
        collection.updated_at || collection.created_at || Time.current
    end

    def enqueue(collection, member, identity, confidence, observed_at)
      Outbox::IsolatedWrite.call("baseline mapping for #{member.item_key}") do
        OutboxEntry.enqueue(
          record_kind: :mapping,
          payload: payload_for(collection, member, identity, confidence, observed_at),
          service_type: identity[:service_type],
          service_instance: identity[:service_instance],
          external_id: identity[:external_id],
          sync_collection_id: collection.id,
          observed_at:
        )
      end
    end

    def payload_for(collection, member, identity, confidence, observed_at)
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
        mapping_confidence: confidence,
        mapping_source: SOURCE.fetch(collection.mapping_method, collection.mapping_method),
        provenance: {
          method: collection.mapping_method,
          confidence: collection.mapping_confidence,
          metadata: collection.mapping_metadata,
          detected_by: "backfill",
          backfilled_at: Time.current.utc.iso8601(6)
        }
      }
    end

    def report
      {
        enqueued: @enqueued,
        by_service: @by_service,
        by_confidence: @by_confidence,
        skipped: @skipped
      }
    end
  end
end
