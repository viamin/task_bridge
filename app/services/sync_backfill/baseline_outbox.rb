# frozen_string_literal: true

module SyncBackfill
  # Seeds the local outbox (RDR #215) with baseline rows for existing
  # synchronized data (#222): one `item` snapshot per persisted sync item
  # and one `mapping` row per publishable SyncCollection membership.
  #
  # Baseline rows describe current state, not history: item rows carry
  # provenance.detected_by "backfill" plus a backfilled_at timestamp and no
  # snapshot_seen observations are fabricated, so TaskBridge Web starts
  # from the known current state and only later diffs become change events.
  # Items the live pipeline (#219) has never observed also get their
  # last_snapshot diff baseline seeded, so the next live refresh publishes
  # only real changes instead of repeating the baseline as snapshot_seen.
  #
  # Deterministic observed_at values (each record's own observation
  # timestamps) keep idempotency keys stable, so rerunning the backfill
  # never duplicates rows. Low-confidence (unevidenced) mappings are
  # withheld from publication per the #222 clarification and only reported
  # in the summary; sync-run rows are never backfilled because
  # sync_service_states has no reliable per-run timestamps. The backfill
  # reads only local database state — it never contacts external services.
  class BaselineOutbox
    DETECTED_BY = "backfill"
    WITHHELD_CONFIDENCE = "low"
    MISSING_EXTERNAL_ID = "missing_external_id"
    MISSING_MAPPING_CONFIDENCE = "missing_mapping_confidence"

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run: false)
      @dry_run = dry_run
      @backfilled_at = Time.current
      @summary = BaselineSummary.new(dry_run:)
    end

    def run!
      return dry_run! if dry_run

      perform
      summary
    end

    private

    attr_reader :dry_run, :backfilled_at, :summary

    def perform
      SyncBackfill::SourceProvenance.run!
      backfill_items
      backfill_mappings
    end

    # Previews the exact rows a write run would enqueue. The whole backfill
    # — including the #216/#217 provenance backfill, whose results change
    # what is eligible — runs inside a transaction that is rolled back, so
    # the counts reflect the state a real run would produce while nothing
    # is persisted.
    def dry_run!
      ActiveRecord::Base.transaction(requires_new: true) do
        perform
        raise ActiveRecord::Rollback
      end
      summary
    end

    def backfill_items
      Base::SyncItem.find_each do |item|
        service_name = item.service_name
        if item.external_id.blank?
          summary.skip_item(service_name, MISSING_EXTERNAL_ID)
          next
        end

        enqueue_item_row(item)
        summary.count_item(service_name)
      end
    end

    def enqueue_item_row(item)
      snapshot = published(item.normalized_snapshot)
      entry = Outbox::IsolatedWrite.call("baseline item snapshot for #{item.item_key}") do
        OutboxEntry.enqueue(record_kind: :item, payload: item_payload(snapshot), **enqueue_context(item))
      end
      # Seed the diff baseline only once the row is safely in the outbox:
      # a dropped write leaves last_snapshot blank so the next live refresh
      # re-detects the item as a first observation (at-least-once).
      seed_diff_baseline(item, snapshot) if entry
    end

    # The published snapshot form: identical to the item's
    # normalized_snapshot with timestamps rendered as ISO 8601 UTC so JSON
    # round-trips keep microsecond precision, plus the baseline marking
    # (#222 clarification: extra payload fields are safe because version 1
    # consumers must ignore unknown fields).
    def item_payload(snapshot)
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        provenance: { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(backfilled_at) }
      )
    end

    def enqueue_context(item)
      identity = Outbox::SourceIdentity.for(item)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: item.last_observed_at || item.updated_at || backfilled_at
      }
    end

    # The backfill establishes the diff baseline for items the live
    # pipeline has never observed, in the same published form
    # Outbox::ObservationEmitter stores. Items already carrying a baseline
    # are never overwritten.
    def seed_diff_baseline(item, snapshot)
      return if item.read_attribute(:last_snapshot).present?

      Outbox::IsolatedWrite.call("baseline snapshot for #{item.item_key}") do
        item.update_column(:last_snapshot, snapshot)
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        eligible, ineligible = collection.sync_items.to_a.partition(&:external_id)
        ineligible.each { summary.skip_mapping(MISSING_EXTERNAL_ID) }
        next if eligible.empty?

        confidence = collection.mapping_confidence.to_s
        if confidence.blank?
          eligible.each { summary.skip_mapping(MISSING_MAPPING_CONFIDENCE) }
        elsif confidence == WITHHELD_CONFIDENCE
          summary.withhold_mapping(collection, confidence, eligible.length)
        else
          emit_mapping_rows(collection, eligible, confidence)
        end
      end
    end

    def emit_mapping_rows(collection, members, confidence)
      Outbox::MappingEmitter.emit_for_members(
        collection,
        members:,
        observed_at: mapping_observed_at(collection),
        provenance_extras: { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(backfilled_at) }
      )
      members.each { summary.count_mapping(confidence) }
    end

    # Deterministic across reruns (SourceProvenance only stamps collections
    # once), so the mapping idempotency key is stable and reruns dedupe.
    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || backfilled_at
    end

    def published(snapshot)
      snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
