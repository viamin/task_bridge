# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox (RDR #215) with a safe baseline for TaskBridge Web: one
  # current-state item snapshot per existing sync_item and one mapping row
  # per sync_collection membership held at `confirmed` or `inferred`
  # confidence. `low`/`tentative` mappings are withheld from publication
  # (see docs/rdr-215-taskbridge-observation-publication-contract.md, "Open
  # Questions") but still counted so they stay identifiable for manual
  # cleanup or Web-side review.
  #
  # Idempotent: OutboxEntry.enqueue dedupes on idempotency_key, and this
  # backfill never mutates sync_items/sync_collections, so observed_at
  # inputs (and therefore keys) stay stable across reruns.
  class OutboxBaseline
    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run: false)
      @dry_run = dry_run
      @summary = Summary.new
    end

    def run!
      backfill_item_snapshots
      backfill_mappings
      summary.to_h
    end

    private

    attr_reader :dry_run, :summary

    def backfill_item_snapshots
      Base::SyncItem.find_each { |item| backfill_item(item) }
    end

    def backfill_item(item)
      return summary.record_item_skipped if item.external_id.blank?

      identity = Outbox::SourceIdentity.for(item)
      enqueue_item_snapshot(item, identity) unless dry_run
      summary.record_item(identity[:service_type])
    end

    def enqueue_item_snapshot(item, identity)
      observed_at = item.last_observed_at || item.updated_at || item.created_at || Time.current
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: ItemSnapshotPayload.call(item, identity, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_mapping(collection) }
    end

    def backfill_mapping(collection)
      confidence = collection.mapping_confidence
      members = collection.sync_items.to_a
      return summary.record_mapping_skipped(count: [members.size, 1].max) if confidence.blank?

      eligible_members = members.select { |member| member.external_id.present? }
      summary.record_mapping(confidence, count: eligible_members.size)
      summary.record_mapping_skipped(count: members.size - eligible_members.size)
      return summary.record_mapping_withheld(count: eligible_members.size) if confidence == "low"

      emit_mapping(collection, eligible_members) unless dry_run
    end

    def emit_mapping(collection, members)
      observed_at = collection.mapping_last_observed_at || collection.updated_at || Time.current
      Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at:)
    end
  end
end
