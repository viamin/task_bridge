# frozen_string_literal: true

module SyncBackfill
  # Enqueues the baseline TaskBridge Web publication rows (RDR #215, issue
  # #222) for existing sync data, so TaskBridge Web starts from known
  # current state and only later diffs arrive as change history:
  #
  # - one `item` current-state snapshot row per existing sync item, marked
  #   as baseline via provenance (`detected_by: "backfill"` plus a
  #   `backfilled_at` timestamp) instead of pretending to be a historical
  #   change event;
  # - one `mapping` row per existing SyncCollection membership, withheld
  #   for low-confidence (contract `tentative`) mappings — the #222
  #   decision resolving RDR #215's open question. Withheld memberships
  #   stay identifiable through the dry-run summary for manual cleanup or
  #   Web-side review;
  # - no `observation` rows (the item snapshot is the baseline, not a
  #   `snapshot_seen` event) and no `sync_run` rows (sync_service_states
  #   holds no reliable per-run start/end timestamps).
  #
  # The backfill is strictly local: existing rows are read, identity and
  # mapping provenance are backfilled first
  # (SyncBackfill::SourceProvenance), the outbox is filled, and each
  # item's diff baseline (`last_snapshot`) is stamped so the live
  # observation pipeline treats this state as known current state.
  # External source systems are never contacted.
  #
  # Rows carry deterministic idempotency keys derived from stable data
  # (`last_observed_at` / `mapping_established_at`), so the backfill can
  # be run any number of times without duplicating rows: re-enqueueing an
  # existing key returns the stored row untouched.
  class BaselineOutbox
    DETECTED_BY = "backfill"

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    # Human-readable summary lines shared by the write and dry-run rake
    # tasks so both report the same shape.
    def self.format_summary(summary)
      scope = summary[:dry_run] ? "would enqueue" : "enqueued"
      mode = summary[:dry_run] ? "dry run" : "complete"
      [
        "Baseline backfill #{mode}: #{scope} #{total(summary[:items_by_service])} item snapshot row(s) " \
        "(#{format_counts(summary[:items_by_service])})",
        "#{scope} #{total(summary[:mappings_by_confidence])} mapping row(s) " \
        "(#{format_counts(summary[:mappings_by_confidence])}); withheld #{summary[:mappings_withheld]} " \
        "low-confidence membership(s) across #{summary[:withheld_collections].length} collection(s)",
        *summary[:withheld_collections].map do |collection|
          "  withheld collection #{collection[:id]} " \
            "#{collection[:title].inspect} " \
            "(#{collection[:confidence]}, #{collection[:members]} member(s))"
        end,
        "Skipped/incomplete: #{total(summary[:items_skipped])} item(s) without external_id " \
        "(#{format_counts(summary[:items_skipped])}), #{summary[:mapping_members_skipped]} mapping member(s) " \
        "without external_id, #{summary[:collections_without_confidence]} collection(s) without mapping confidence"
      ]
    end

    def self.format_counts(counts)
      return "none" if counts.blank?

      counts.sort_by { |service, _| service }.map { |service, count| "#{service}=#{count}" }.join(", ")
    end

    def self.total(counts)
      counts.values.sum
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
    end

    def run!
      @summary = {
        dry_run:,
        items_by_service: {},
        items_skipped: {},
        mappings_by_confidence: {},
        mappings_withheld: 0,
        withheld_collections: [],
        mapping_members_skipped: 0,
        collections_without_confidence: 0
      }
      @existing_item_rows = OutboxEntry.where(record_kind: "item").count
      @existing_mapping_rows = OutboxEntry.where(record_kind: "mapping").count
      SyncBackfill::SourceProvenance.run! unless dry_run
      backfill_items
      backfill_collections
      record_created_counts
      summary
    end

    private

    attr_reader :now, :summary

    def dry_run
      @dry_run == true
    end

    def backfill_items
      Base::SyncItem.find_each do |item|
        service_type = Base::Service.service_identifier_for(item.provider)
        if item.external_id.blank?
          bump(summary[:items_skipped], service_type)
          next
        end

        bump(summary[:items_by_service], service_type)
        next if dry_run

        enqueue_item_row(item)
      end
    end

    def enqueue_item_row(item)
      snapshot = baseline_snapshot_for(item)
      identity = Outbox::SourceIdentity.for(item)
      row = OutboxEntry.enqueue(
        record_kind: :item,
        payload: snapshot.merge(
          "contract_version" => OutboxEntry::PAYLOAD_VERSION,
          "provenance" => { "detected_by" => DETECTED_BY, "backfilled_at" => iso(now) }
        ),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: item.last_observed_at
      )
      # Stamp the diff baseline only once the row is safely enqueued, so
      # the live pipeline re-detects (at-least-once) anything this run
      # failed to record.
      item.update_column(:last_snapshot, snapshot) if row && item.last_snapshot != snapshot
    end

    # The stored live baseline wins when present: it was serialized with
    # the full external context (adapter metadata, display title) that a
    # database-only read cannot reconstruct. Otherwise the snapshot is
    # rebuilt from persisted state for the first time.
    def baseline_snapshot_for(item)
      stored = item.read_attribute(:last_snapshot)
      return stored if stored.present?

      Base::SnapshotSerializer.published(item)
                              .deep_stringify_keys
                              .merge("observed_at" => iso(item.last_observed_at))
    end

    def backfill_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = resolved_confidence(collection)
        if confidence.blank?
          summary[:collections_without_confidence] += 1
          next
        end

        eligible_members, skipped_members = collection.sync_items.to_a.partition { |member| member.external_id.present? }
        summary[:mapping_members_skipped] += skipped_members.length
        publish_mapping_rows(collection, eligible_members, confidence)
      end
    end

    def publish_mapping_rows(collection, eligible_members, confidence)
      unless Outbox::MappingEmitter.publishable_confidence?(confidence)
        summary[:mappings_withheld] += eligible_members.length
        summary[:withheld_collections] << {
          id: collection.id,
          title: collection.title,
          confidence: Outbox::MappingEmitter.contract_confidence_for(confidence),
          members: eligible_members.length
        }
        return
      end

      bump_by(summary[:mappings_by_confidence], Outbox::MappingEmitter.contract_confidence_for(confidence), eligible_members.length)
      return if dry_run

      Outbox::MappingEmitter.emit_for_members(
        collection,
        members: eligible_members,
        observed_at: collection.mapping_established_at || collection.created_at || now,
        provenance_extras: { "detected_by" => DETECTED_BY, "backfilled_at" => iso(now) }
      )
    end

    # Stored provenance wins (the write path persists it first via
    # SyncBackfill::SourceProvenance); resolving in memory keeps dry-run
    # counts honest for data the provenance backfill has not touched yet.
    def resolved_confidence(collection)
      return collection.mapping_confidence if collection.mapping_method.present?

      SyncBackfill::SourceProvenance.provenance_for(collection)[:confidence]
    end

    def record_created_counts
      summary[:item_rows_created] = OutboxEntry.where(record_kind: "item").count - @existing_item_rows
      summary[:mapping_rows_created] = OutboxEntry.where(record_kind: "mapping").count - @existing_mapping_rows
    end

    def bump(counts, key)
      bump_by(counts, key, 1)
    end

    def bump_by(counts, key, amount)
      counts[key] = counts[key].to_i + amount
    end

    def iso(time)
      time.utc.iso8601(6)
    end
  end
end
