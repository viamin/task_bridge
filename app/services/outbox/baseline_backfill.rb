# frozen_string_literal: true

module Outbox
  # Seeds the local outbox with baseline rows for existing sync data
  # (RDR #215 "Migration and Backfill Implications", issue #222) so
  # TaskBridge Web can start from known current state and treat later
  # diffs as change history. Emits:
  #
  # * one `item` current-state snapshot per existing sync item;
  # * one `mapping` row per existing SyncCollection membership held at
  #   `high` or `medium` confidence. Low/unknown-confidence memberships
  #   are withheld (the RDR #215 open question, resolved for backfill in
  #   #222) and stay identifiable through the summary counts by
  #   confidence.
  #
  # Baseline rows are marked, not replayed as history: every payload
  # carries `provenance.detected_by: "backfill"` and a `backfilled_at`
  # stamp, and observed_at is derived deterministically from the source
  # row (first_observed_at/mapping_established_at), so reruns reuse the
  # same idempotency keys and never duplicate rows or rewrite stored
  # payloads. No `sync_run` rows are backfilled: sync_service_states has
  # no reliable per-run start/end timestamps (RDR #215 requires them).
  # The backfill only reads sync data and writes outbox rows — it never
  # touches external source systems.
  class BaselineBackfill
    DETECTED_BY = "backfill"
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze
    UNKNOWN_CONFIDENCE = "unknown"
    TALLIED_OUTCOMES = %i[enqueued already_present skipped_incomplete withheld write_failures].freeze

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run: false, now: Time.current)
      @dry_run = dry_run
      @now = now
      @items = { candidates: 0, enqueued: 0, already_present: 0, skipped_incomplete: 0,
                 write_failures: 0, by_service: {} }
      @mappings = { collections: 0, memberships: 0, enqueued: 0, already_present: 0,
                    withheld: 0, skipped_incomplete: 0, write_failures: 0, by_confidence: {} }
    end

    def run!
      backfill_items
      backfill_collections
      { dry_run: @dry_run, items: @items, mappings: @mappings }
    end

    private

    def backfill_items
      Base::SyncItem.find_each { |item| backfill_item(item) }
    end

    def backfill_item(item)
      identity = Outbox::SourceIdentity.for(item)
      @items[:candidates] += 1
      observed_at = item.first_observed_at || item.updated_at || item.created_at
      result = if identity[:external_id].blank?
        :skipped_incomplete
      else
        enqueue_item(item, identity, observed_at)
      end
      tally(@items, :by_service, identity[:service_type], result)
    end

    def enqueue_item(item, identity, observed_at)
      context = {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
      return dry_run_outcome(:item, **context) if @dry_run

      Outbox::IsolatedWrite.call("baseline item for #{item.item_key}") do
        OutboxEntry.enqueue(record_kind: :item, payload: item_payload(item, observed_at), **context)
      end
    end

    # The published snapshot (ISO 8601 timestamps so JSON round-trips stay
    # diff-stable) marked as a baseline fact rather than a change event.
    def item_payload(item, observed_at)
      item.normalized_snapshot
          .merge(observed_at:)
          .deep_transform_values { |value| value.respond_to?(:utc) ? iso_timestamp(value) : value }
          .merge(
            contract_version: OutboxEntry::PAYLOAD_VERSION,
            provenance: { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(@now) }
          )
    end

    def backfill_collections
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
    end

    def backfill_collection(collection)
      members = collection.sync_items.to_a
      confidence = collection.mapping_confidence.presence || UNKNOWN_CONFIDENCE
      @mappings[:collections] += 1
      @mappings[:memberships] += members.length
      complete, incomplete = members.partition { |member| member.external_id.present? }
      incomplete.each { tally(@mappings, :by_confidence, confidence, :skipped_incomplete) }
      return publish_members(collection, complete, confidence) if publishable?(confidence)

      complete.each { tally(@mappings, :by_confidence, confidence, :withheld) }
    end

    def publishable?(confidence)
      PUBLISHABLE_CONFIDENCES.include?(confidence)
    end

    def publish_members(collection, members, confidence)
      observed_at = collection.mapping_established_at || collection.updated_at || collection.created_at
      results = if @dry_run
        members.map { |member| dry_run_mapping_outcome(collection, member, observed_at) }
      else
        MappingEmitter.emit_for_members(collection, members:, observed_at:, extra_provenance:)
      end
      results.each { |result| tally(@mappings, :by_confidence, confidence, outcome_of(result)) }
    end

    def extra_provenance
      { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(@now) }
    end

    def dry_run_mapping_outcome(collection, member, observed_at)
      identity = Outbox::SourceIdentity.for(member)
      dry_run_outcome(:mapping, observed_at:, sync_collection_id: collection.id, **identity)
    end

    # Dry runs never write: they predict the row's deterministic
    # idempotency key and report whether it already exists.
    def dry_run_outcome(record_kind, observed_at:, service_instance:, external_id:, **identity)
      key = Outbox::IdempotencyKey.for(
        record_kind:, observed_at:, service_instance:, external_id:, **identity
      )
      OutboxEntry.exists?(idempotency_key: key) ? :already_present : :enqueued
    end

    def outcome_of(result)
      return :write_failures if result.nil?
      return result if result.is_a?(Symbol)

      result.previously_new_record? ? :enqueued : :already_present
    end

    def tally(summary, group_field, group, outcome)
      outcome = outcome_of(outcome)
      summary[outcome] += 1
      bucket = summary[group_field][group] ||= TALLIED_OUTCOMES.index_with(0)
      bucket[outcome] += 1
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
