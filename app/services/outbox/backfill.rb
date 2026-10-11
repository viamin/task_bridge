# frozen_string_literal: true

module Outbox
  # Seeds the local outbox with baseline rows for TaskBridge's existing
  # data (RDR #215 "Migration and Backfill Implications", issue #222) so
  # TaskBridge Web starts from known current state and only later diffs
  # become change history.
  #
  # What it writes — and deliberately does not:
  # - one `item` current-state snapshot per existing sync item, marked as
  #   baseline via `provenance.detected_by: "backfill"` and
  #   `provenance.backfilled_at`. No `snapshot_seen` observation rows: a
  #   baseline is not a historical change event, and the live pipeline
  #   (#219) emits the first observation on its next refresh.
  # - `mapping` rows for existing sync collection memberships, except
  #   low-confidence (`tentative`) memberships, which are withheld from
  #   publication (resolved RDR #215 open question) and reported in the
  #   summary counts for manual cleanup or Web-side review.
  # - no `sync_run` rows: `sync_service_states` keeps no reliable per-run
  #   start/end timestamps, which RDR #215 requires for backfilled
  #   summaries. Live sync runs publish them going forward (#219-#221).
  #
  # Idempotency: every idempotency key is derived from data that does not
  # change between runs (each record's own observation timestamps), so
  # rerunning re-finds the stored rows instead of duplicating them. The
  # backfill reads and writes local data only — external source systems
  # are never contacted or mutated.
  class Backfill
    DETECTED_BY = "backfill"
    WITHHELD_CONFIDENCE = "tentative"

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run: false, now: Time.current)
      @dry_run = dry_run
      @now = now
      @items_by_service = Hash.new(0)
      @skipped_items = Hash.new(0)
      @memberships_by_confidence = Hash.new(0)
      @withheld_by_confidence = Hash.new(0)
      @collections = 0
    end

    def run!
      # Identity/provenance backfill (#217) runs first so legacy rows get
      # the service instance names and mapping evidence stored on disk
      # before identities are derived from them. Dry runs never mutate.
      SyncBackfill::SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :now, :dry_run

    def backfill_items
      # Untyped rows cannot resolve a provider; count them without
      # instantiating (which would raise) so they surface for manual repair.
      untyped_count = Base::SyncItem.untyped.count
      @skipped_items["untyped_item"] += untyped_count if untyped_count.positive?
      Base::SyncItem.typed.find_each do |item|
        identity = Outbox::SourceIdentity.for(item)
        if identity[:external_id].present?
          enqueue_item_snapshot(item, identity) unless dry_run
          @items_by_service[identity[:service_type]] += 1
        else
          @skipped_items["missing_external_id"] += 1
        end
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        @collections += 1
        members = collection.sync_items.select { |member| Outbox::MappingEmitter.eligible?(member) }
        confidence = published_confidence(collection)
        if withhold?(confidence)
          members.each { @withheld_by_confidence[confidence] += 1 }
          next
        end

        unless dry_run
          Outbox::MappingEmitter.emit_for_members(collection, members:,
                                                              observed_at: mapping_observed_at(collection))
        end
        members.each { @memberships_by_confidence[confidence] += 1 }
      end
    end

    def enqueue_item_snapshot(item, identity)
      observed_at = item_observed_at(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, observed_at),
        **enqueue_context(identity, item, observed_at)
      )
    end

    def item_payload(item, observed_at)
      published_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso(observed_at),
        provenance: { detected_by: DETECTED_BY, backfilled_at: iso(now) }
      )
    end

    # The published snapshot form: identical to normalized_snapshot but
    # with timestamps rendered as ISO 8601 UTC (mirrors
    # Outbox::ObservationEmitter#published_snapshot) so JSON round-trips
    # keep microsecond precision.
    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso(value) : value
      end
    end

    def enqueue_context(identity, item, observed_at)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
    end

    # Deterministic per record so reruns reuse the same idempotency key.
    def item_observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    # Unknown confidence is treated like the withheld bucket rather than
    # published: backfill publishes only what it can classify, per RDR
    # #215's safer default for the resolved open question.
    def published_confidence(collection)
      return WITHHELD_CONFIDENCE if collection.mapping_confidence.blank?

      Outbox::MappingEmitter.confidence_for(collection)
    end

    def withhold?(confidence)
      confidence == WITHHELD_CONFIDENCE
    end

    def summary
      {
        dry_run: @dry_run,
        items: {
          enqueued_by_service: @items_by_service,
          skipped_by_reason: @skipped_items
        },
        mappings: {
          collections: @collections,
          enqueued_by_confidence: @memberships_by_confidence,
          withheld_by_confidence: @withheld_by_confidence
        }
      }
    end

    def iso(time)
      time&.utc&.iso8601(6)
    end
  end
end
