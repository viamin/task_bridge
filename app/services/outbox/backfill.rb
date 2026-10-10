# frozen_string_literal: true

module Outbox
  # Backfills baseline publication rows for existing TaskBridge data into
  # the local outbox (RDR #215 "Migration and Backfill Implications",
  # issue #222): one `item` snapshot per known sync item plus `mapping`
  # rows for existing SyncCollection memberships, so TaskBridge Web can
  # start from the known current state and treat later observations as
  # change history.
  #
  # Baseline rows are marked, never dressed up as history: item payloads
  # carry provenance `detected_by: "backfill"` with a `backfilled_at`
  # timestamp, and no `snapshot_seen` observations or sync-run summaries
  # are invented (sync_service_states has no reliable per-run timestamps).
  #
  # Low-confidence (tentative) memberships are withheld from publication —
  # the resolution of RDR #215's open question — and stay identifiable
  # through the dry-run summary's counts by confidence.
  #
  # Safe to rerun: every row's idempotency key is derived from stable
  # per-record timestamps, so a second run writes nothing new and never
  # rewrites a stored payload. The backfill reads only local tables; it
  # never contacts or mutates an external source system.
  class Backfill
    DETECTED_BY = "backfill"
    PUBLISHED_CONFIDENCES = %w[confirmed inferred].freeze
    UNKNOWN_CONFIDENCE = "unknown"

    def self.run!(dry_run: false, now: Time.current, output: $stdout)
      new(dry_run:, now:, output:).run!
    end

    def initialize(dry_run:, now:, output:)
      @dry_run = dry_run
      @now = now
      @output = output
      reset_counts
    end

    def run!
      # Complete the identity/provenance backfill (#216-#218) first so
      # legacy rows publish under their inferred service instance instead
      # of the permanent default one. Dry runs stay read-only.
      SyncBackfill::SourceProvenance.run! unless dry_run?
      backfill_items
      backfill_mappings
      print_summary
      summary
    end

    private

    attr_reader :now, :output, :counts

    def dry_run?
      @dry_run
    end

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          counts[:skipped_items] += 1
          next
        end

        counts[:items] += 1
        counts[:items_by_service][Outbox::SourceIdentity.for(item)[:service_type]] += 1
        enqueue_item_row(item) unless dry_run?
      end
    end

    def enqueue_item_row(item)
      Outbox::IsolatedWrite.call("backfill item for #{item.item_key}") do
        observed_at = item.last_observed_at || item.updated_at || item.created_at
        row = OutboxEntry.enqueue(
          record_kind: :item,
          payload: ItemPayload.call(item, observed_at:, backfilled_at: now),
          **item_context(item, observed_at)
        )
        count_written(:item_rows_written, row)
        advance_baseline(item)
        row
      end
    end

    def item_context(item, observed_at)
      identity = Outbox::SourceIdentity.for(item)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
    end

    # Store the same published snapshot form the live emitter stores
    # (#219), so each item's next refresh diffs against the backfilled
    # baseline and publishes only real changes instead of re-discovering
    # the item. update_column deliberately skips timestamps: observed_at
    # derives from them and must stay stable across reruns.
    def advance_baseline(item)
      snapshot = published_snapshot_for(item)
      return if item.read_attribute(:last_snapshot) == snapshot.deep_stringify_keys

      item.update_column(:last_snapshot, snapshot)
    end

    def published_snapshot_for(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? value.utc.iso8601(6) : value
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at
        collection.sync_items.each do |member|
          backfill_membership(collection, member, observed_at)
        end
      end
    end

    def backfill_membership(collection, member, observed_at)
      if member.external_id.blank?
        counts[:skipped_memberships] += 1
        return
      end

      confidence = Outbox::MappingEmitter.contract_confidence_for(collection)
      counts[:mappings_by_confidence][confidence.presence || UNKNOWN_CONFIDENCE] += 1
      if PUBLISHED_CONFIDENCES.include?(confidence)
        counts[:mappings] += 1
        enqueue_mapping_row(collection, member, observed_at) unless dry_run?
      else
        counts[:withheld_mappings] += 1
      end
    end

    def enqueue_mapping_row(collection, member, observed_at)
      Outbox::IsolatedWrite.call("backfill mapping for #{member.item_key}") do
        payload = Outbox::MappingEmitter.payload_for(collection, member, observed_at)
        payload[:provenance] = payload[:provenance].merge(
          detected_by: DETECTED_BY,
          backfilled_at: now.utc.iso8601(6)
        )
        identity = Outbox::SourceIdentity.for(member)
        row = OutboxEntry.enqueue(
          record_kind: :mapping,
          payload:,
          service_type: identity[:service_type],
          service_instance: identity[:service_instance],
          external_id: identity[:external_id],
          sync_collection_id: collection.id,
          observed_at:
        )
        count_written(:mapping_rows_written, row)
        row
      end
    end

    def count_written(key, row)
      counts[key] += 1 if row&.previously_new_record?
    end

    def reset_counts
      @counts = {
        items: 0,
        item_rows_written: 0,
        mappings: 0,
        mapping_rows_written: 0,
        withheld_mappings: 0,
        skipped_items: 0,
        skipped_memberships: 0,
        items_by_service: Hash.new(0),
        mappings_by_confidence: Hash.new(0)
      }
    end

    def summary
      counts.merge(
        status: dry_run? ? "dry_run" : "backfilled",
        items_by_service: sorted_counts(counts[:items_by_service]),
        mappings_by_confidence: sorted_counts(counts[:mappings_by_confidence])
      )
    end

    def sorted_counts(count_hash)
      count_hash.sort.to_h
    end

    def print_summary
      return unless output

      if dry_run?
        output.puts "Outbox backfill dry run: would enqueue #{counts[:items]} item snapshots and " \
                    "#{counts[:mappings]} mapping rows (nothing was written)"
      else
        output.puts "Outbox backfill: wrote #{counts[:item_rows_written]} item rows and " \
                    "#{counts[:mapping_rows_written]} mapping rows"
      end
      output.puts "  item snapshots by service: #{format_counts(counts[:items_by_service])}"
      output.puts "  mapping memberships by confidence: #{format_counts(counts[:mappings_by_confidence])} " \
                  "(#{counts[:withheld_mappings]} withheld from publication)"
      output.puts "  skipped: #{counts[:skipped_items]} items and #{counts[:skipped_memberships]} " \
                  "memberships missing an external id"
      print_provenance_hint if dry_run?
    end

    # A dry run cannot complete the source-provenance backfill itself (it
    # writes nothing), so flag rows whose identity would still change.
    def print_provenance_hint
      return unless identity_backfill_pending?

      output.puts "  note: some records have not completed the source provenance backfill; " \
                  "the real run performs it first — preview `rake task_bridge:backfill_sync_provenance`"
    end

    def identity_backfill_pending?
      Base::SyncItem.where(last_observed_at: nil).exists? ||
        SyncCollection.where(mapping_method: nil).exists?
    end

    def format_counts(count_hash)
      count_hash.sort.map { |name, count| "#{name}=#{count}" }.join(", ").presence || "none"
    end
  end
end
