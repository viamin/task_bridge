# frozen_string_literal: true

module SyncBackfill
  # Backfills the local outbox with baseline rows for data TaskBridge
  # already holds (#222, RDR #215 "Migration and Backfill Implications") so
  # TaskBridge Web can start from known current state and treat only later
  # diffs as change history:
  #
  # - one `item` snapshot per existing sync item, marked as a backfilled
  #   baseline through provenance metadata (`detected_by: "backfill"`,
  #   `baseline: true`, `backfilled_at`) rather than presented as a
  #   historical change event — no `observation` rows are produced;
  # - one `mapping` row per SyncCollection membership, except memberships
  #   held at low confidence, which stay withheld from publication (the
  #   resolved RDR #215 open question) and remain identifiable through the
  #   dry-run summary's counts by confidence;
  # - no `sync_run` rows: sync_service_states has no reliable per-run
  #   started_at/finished_at, and live runs publish those going forward
  #   (#219-#221).
  #
  # Identity and mapping provenance are backfilled first through
  # SyncBackfill::SourceProvenance, and every row carries a deterministic
  # idempotency key derived from stable per-row timestamps (each row's
  # last_observed_at / mapping_last_observed_at), so the backfill can run
  # any number of times without duplicating rows. The backfill only reads
  # persisted rows: it never contacts external source systems.
  class BaselineOutbox
    DETECTED_BY = "backfill"
    # Internal confidences published by the backfill; everything else —
    # `low` plus unknown values — is withheld (#222 resolves the RDR #215
    # open question in favor of withholding tentative mappings).
    PUBLISHED_CONFIDENCES = %w[high medium].freeze
    UNKNOWN_CONFIDENCE = "unknown"

    class << self
      def run!(backfilled_at: Time.current)
        backfill = new(backfilled_at:)
        backfill.perform
        backfill.summary
      end

      # Executes the exact write path — including the provenance backfill —
      # inside a transaction that always rolls back: the returned counts are
      # what a real run would write, while the database stays untouched.
      def dry_run!(backfilled_at: Time.current)
        backfill = new(backfilled_at:, dry_run: true)
        backfill.perform_rolled_back
        backfill.summary
      end
    end

    def initialize(backfilled_at: Time.current, dry_run: false)
      @backfilled_at = backfilled_at
      @dry_run = dry_run
    end

    def perform
      SyncBackfill::SourceProvenance.run!
      backfill_items
      backfill_mappings
    end

    def perform_rolled_back
      ActiveRecord::Base.transaction do
        perform
        raise ActiveRecord::Rollback
      end
    end

    def summary
      @summary ||= {
        dry_run: @dry_run,
        items: { enqueued: 0, existing: 0, skipped: 0, errors: 0, by_service: {} },
        mappings: {
          enqueued: 0, existing: 0, withheld: 0, skipped_members: 0, errors: 0,
          by_confidence: {}, withheld_by_confidence: {}
        }
      }
    end

    private

    def backfill_items
      Base::SyncItem.find_each { |item| backfill_item(item) }
    end

    def backfill_item(item)
      identity = Outbox::SourceIdentity.for(item)
      return summary[:items][:skipped] += 1 if identity[:external_id].blank?

      row = Outbox::IsolatedWrite.call("baseline item snapshot for #{item.item_key}") do
        OutboxEntry.enqueue(
          record_kind: :item,
          payload: Base::SnapshotSerializer.published(item).merge(provenance: baseline_provenance),
          **item_context(item, identity)
        )
      end
      return summary[:items][:errors] += 1 if row.nil?

      created = row.previously_new_record?
      summary[:items][:enqueued] += 1 if created
      summary[:items][:existing] += 1 unless created
      bump(summary[:items][:by_service], identity[:service_type])
    rescue StandardError => e
      # A one-off migration over legacy data must not abort on a single
      # broken row: report it, count it, and keep the remaining rows.
      warn "skipping #{item.class.name} ##{item.id} for the baseline backfill (#{e.class}: #{e.message})"
      summary[:items][:errors] += 1
    end

    def item_context(item, identity)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: item_observed_at(item)
      }
    end

    # Stable per item, so reruns rebuild the same idempotency key and
    # OutboxEntry.enqueue dedupes instead of duplicating the baseline.
    def item_observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at
    end

    def baseline_provenance
      {
        detected_by: DETECTED_BY,
        baseline: true,
        backfilled_at: @backfilled_at.utc.iso8601(6)
      }
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
    end

    def backfill_collection(collection)
      eligible_members, incomplete_members = collection.sync_items.to_a
                                                       .partition { |member| member.external_id.present? }
      summary[:mappings][:skipped_members] += incomplete_members.length
      return if eligible_members.empty?

      confidence = collection.mapping_confidence.to_s
      return withhold_members(eligible_members.length, confidence) unless PUBLISHED_CONFIDENCES.include?(confidence)

      rows = Outbox::MappingEmitter.emit_for_members(
        collection,
        members: eligible_members,
        observed_at: mapping_observed_at(collection)
      )
      record_mapping_rows(rows, expected: eligible_members.length, confidence:)
    rescue StandardError => e
      warn "skipping sync_collection ##{collection.id} for the baseline backfill (#{e.class}: #{e.message})"
      summary[:mappings][:errors] += 1
    end

    def withhold_members(count, confidence)
      summary[:mappings][:withheld] += count
      bump(summary[:mappings][:withheld_by_confidence], confidence.presence || UNKNOWN_CONFIDENCE, count)
    end

    # Stable per collection for the same rerun-safety reason as
    # item_observed_at.
    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def record_mapping_rows(rows, expected:, confidence:)
      contract_confidence = Outbox::MappingEmitter::CONFIDENCE.fetch(confidence, confidence)
      rows.each do |row|
        created = row.previously_new_record?
        summary[:mappings][:enqueued] += 1 if created
        summary[:mappings][:existing] += 1 unless created
        bump(summary[:mappings][:by_confidence], contract_confidence)
      end
      # Rows missing relative to the members handed to the emitter are
      # isolated write failures the emitter already reported.
      summary[:mappings][:errors] += expected - rows.length
    end

    def bump(counter_hash, key, count = 1)
      counter_hash[key] = counter_hash.fetch(key, 0) + count
    end
  end
end
