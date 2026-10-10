# frozen_string_literal: true

module SyncBackfill
  # Seeds the local outbox with the baseline current state of data that
  # already existed before the observation pipeline (issue #222): one `item`
  # snapshot per existing sync item and one `mapping` row per existing
  # SyncCollection membership. Rows carry provenance.detected_by
  # "backfill" plus a backfilled_at timestamp so TaskBridge Web can tell a
  # baseline observation from live change history; nothing pretends to be a
  # historical change event, and no snapshot_seen observation rows or
  # sync_run summaries are produced (#222 clarifications).
  #
  # Per the clarified decision resolving RDR #215's open question, only
  # confirmed and inferred mappings are enqueued; low-confidence (tentative)
  # memberships are withheld from publication and reported in the summary
  # for manual cleanup. The backfill never mutates external source systems
  # and never writes sync_items or sync_collections — it only reads them.
  #
  # Idempotency: every row uses the deterministic RDR #215 idempotency key
  # (identity + the item's/collection's stored observed_at), and
  # OutboxEntry.enqueue deduplicates on that key, so re-running the backfill
  # leaves previously enqueued rows untouched.
  class OutboxBaseline
    BACKFILL_DETECTED_BY = "backfill"
    PUBLISHABLE_CONFIDENCE = %w[confirmed inferred].freeze

    def self.run!(dry_run: false, backfilled_at: Time.current, output: $stdout)
      new(dry_run:, backfilled_at:, output:).run!
    end

    def initialize(dry_run:, backfilled_at:, output:)
      @dry_run = dry_run
      @backfilled_at = backfilled_at
      @output = output
      @summary = empty_summary
    end

    def run!
      backfill_item_snapshots
      backfill_collection_mappings
      @output.puts(SyncBackfill::BaselineReport.render(@summary))
      @summary
    end

    private

    attr_reader :backfilled_at

    def empty_summary
      {
        dry_run: @dry_run,
        items: { enqueued: 0, by_service: {}, skipped: {}, write_failures: 0 },
        mappings: { enqueued: 0, by_confidence: {}, withheld: {}, skipped: {}, write_failures: 0 }
      }
    end

    def backfill_item_snapshots
      Base::SyncItem.find_each { |item| backfill_item(item) }
    end

    def backfill_item(item)
      identity = Outbox::SourceIdentity.for(item)
      if item.external_id.blank?
        tally_skipped(:items, "missing_external_id", identity[:service_type])
        return
      end

      tally(:items, :by_service, identity[:service_type])
      return if dry_run?

      written = Outbox::IsolatedWrite.call("baseline item snapshot for #{item.item_key}") do
        OutboxEntry.enqueue(
          record_kind: :item,
          payload: Outbox::ItemSnapshot.for(item, observed_at: item_observed_at(item), provenance: baseline_provenance),
          **enqueue_context(item, identity, item_observed_at(item))
        )
      end
      count_write(:items, written)
    end

    def backfill_collection_mappings
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
    end

    def backfill_collection(collection)
      if collection.mapping_confidence.blank?
        tally_skipped(:mappings, "missing_mapping_metadata", "collections")
        return
      end

      eligible, incomplete = collection.sync_items.to_a.partition { |member| member.external_id.present? }
      incomplete.each do |member|
        tally_skipped(:mappings, "missing_external_id", Outbox::SourceIdentity.for(member)[:service_type])
      end

      bucket = publishable?(collection) ? :by_confidence : :withheld
      eligible.each { tally(:mappings, bucket, translated_confidence(collection)) }
      return if dry_run? || bucket == :withheld

      rows = Outbox::MappingEmitter.emit_for_members(
        collection,
        members: eligible,
        observed_at: collection_observed_at(collection),
        provenance_extras: baseline_provenance
      )
      @summary[:mappings][:enqueued] += rows.length
      @summary[:mappings][:write_failures] += eligible.length - rows.length
    end

    def publishable?(collection)
      PUBLISHABLE_CONFIDENCE.include?(translated_confidence(collection))
    end

    def translated_confidence(collection)
      Outbox::MappingEmitter.translated_confidence(collection)
    end

    def enqueue_context(item, identity, observed_at)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
    end

    # Deterministic across re-runs: the backfill never mutates the rows it
    # reads, so these timestamps are stable between runs and keep the
    # derived idempotency keys stable with them.
    def item_observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at
    end

    def collection_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def baseline_provenance
      @baseline_provenance ||= { detected_by: BACKFILL_DETECTED_BY, backfilled_at: backfilled_at.utc.iso8601(6) }
    end

    def dry_run?
      @dry_run == true
    end

    def tally(section, bucket, key)
      counts = @summary[section][bucket]
      counts[key] = counts.fetch(key, 0) + 1
    end

    def tally_skipped(section, reason, scope)
      scopes = (@summary[section][:skipped][reason] ||= {})
      scopes[scope] = scopes.fetch(scope, 0) + 1
    end

    def count_write(section, written)
      bucket = written ? :enqueued : :write_failures
      @summary[section][bucket] += 1
    end
  end
end
