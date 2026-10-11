# frozen_string_literal: true

module Outbox
  # Backfills the TaskBridge Web baseline (#222) from existing sync data so
  # publication starts from a known current state and only later diffs
  # become change history (RDR #215). Emits exactly one baseline `item`
  # snapshot per existing sync item and `mapping` rows for existing
  # SyncCollection memberships — never `observation` or `sync_run` rows,
  # because a backfilled row is a statement about current state, not a
  # historical change event.
  #
  # Idempotent by construction: each row's idempotency key is derived from
  # the record's own stable timestamps, and reruns skip records that
  # already have a baseline row, so running the backfill repeatedly never
  # duplicates rows — even after live sync traffic has bumped observation
  # timestamps. Low- and unknown-confidence memberships are withheld from
  # publication (the #222 resolution of RDR #215's open question, mapping
  # `high` to `confirmed` and `medium` to `inferred`) and stay identifiable
  # through the summary's counts by confidence. The backfill only writes
  # local rows: it reads existing sync data and never contacts or mutates
  # external source systems.
  class BaselineBackfill
    DETECTED_BY = "backfill"
    PUBLISHED_MAPPING_CONFIDENCE = %w[high medium].freeze

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run: false, now: Time.current)
      @dry_run = dry_run
      @now = now
      @summary = Summary.new(dry_run:)
    end

    def run!
      backfill_items
      backfill_collections
      summary
    end

    private

    attr_reader :now, :summary

    def dry_run?
      @dry_run
    end

    def backfill_items
      Base::SyncItem.includes(:sync_collection).find_each do |item|
        summary.record_item(service_label_for(item), item_outcome_for(item))
      end
    end

    def backfill_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence.presence || Summary::UNKNOWN
        collection.sync_items.each do |member|
          summary.record_mapping(confidence, mapping_outcome_for(collection, member, confidence))
        end
      end
    end

    def item_outcome_for(item)
      return %i[skipped missing_external_id] if item.external_id.blank?

      identity = Outbox::SourceIdentity.for(item)
      return :already_backfilled if baseline_item_row?(identity)
      return :enqueued if dry_run?

      enqueue_item_snapshot(item, identity)
      :enqueued
    rescue StandardError => e
      report_skipped(item, e)
      %i[skipped snapshot_error]
    end

    def mapping_outcome_for(collection, member, confidence)
      return :withheld unless publishable_confidence?(confidence)
      return %i[skipped missing_external_id] if member.external_id.blank?

      identity = Outbox::SourceIdentity.for(member)
      return :already_backfilled if baseline_mapping_row?(collection, identity)

      enqueue_membership(collection, member) unless dry_run?
      :enqueued
    rescue StandardError => e
      report_skipped(member, e)
      %i[skipped mapping_error]
    end

    def enqueue_item_snapshot(item, identity)
      observed_at = item_observed_at(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: ItemPayload.build(
          item,
          observed_at:,
          backfilled_at: now,
          membership_block: membership_block_for(item)
        ),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def enqueue_membership(collection, member)
      MappingEmitter.emit_for_members(
        collection,
        members: [member],
        observed_at: collection_observed_at(collection),
        provenance_extras: { detected_by: DETECTED_BY, backfilled_at: iso(now) }
      )
    end

    # Baseline timestamps are taken from each record's own history (not the
    # wall clock) so a rerun rebuilds the same idempotency keys: reruns
    # dedupe against the stored rows instead of minting new ones.
    def item_observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at || now
    end

    def collection_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || now
    end

    # The item snapshot's membership block is published only when the
    # mapping itself is publishable; a withheld low-confidence membership
    # asserts nothing on the item row.
    def membership_block_for(item)
      collection = item.sync_collection
      return if collection.nil?
      return unless publishable_confidence?(collection.mapping_confidence)

      {
        sync_collection_id: collection.id,
        membership_role: MappingEmitter::MEMBERSHIP_ROLE,
        mapping_confidence: MappingEmitter::CONFIDENCE.fetch(collection.mapping_confidence, collection.mapping_confidence),
        mapping_source: MappingEmitter::SOURCE.fetch(collection.mapping_method, collection.mapping_method)
      }
    end

    def publishable_confidence?(confidence)
      PUBLISHED_MAPPING_CONFIDENCE.include?(confidence)
    end

    def baseline_item_row?(identity)
      OutboxEntry.exists?(
        record_kind: "item",
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id]
      )
    end

    def baseline_mapping_row?(collection, identity)
      OutboxEntry.exists?(
        record_kind: "mapping",
        sync_collection_id: collection.id,
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id]
      )
    end

    def service_label_for(item)
      Base::Service.service_identifier_for(item.provider)
    rescue StandardError
      Summary::UNKNOWN
    end

    def report_skipped(record, error)
      warn "[Outbox] skipping baseline row for #{record.class.name} #{record.id} (#{error.class}: #{error.message})"
    end

    def iso(time)
      time.utc.iso8601(6)
    end
  end
end
