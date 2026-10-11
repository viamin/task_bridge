# frozen_string_literal: true

module SyncBackfill
  # Seeds the local outbox (#222) with a baseline of existing TaskBridge
  # data so TaskBridge Web starts from known current state and only later
  # diffs become change history (RDR #215, "Migration and Backfill
  # Implications"). The backfill emits one current-state `item` snapshot
  # per existing sync item and `mapping` rows for existing SyncCollection
  # memberships; it writes no sync_run rows (sync_service_states holds no
  # reliable per-run timestamps) and no `snapshot_seen` observations
  # (baseline rows are not historical change events — they carry
  # `provenance.detected_by: "backfill"` and a `backfilled_at` timestamp
  # instead).
  #
  # Per the clarified #222 decision that resolved RDR #215's open question,
  # only `confirmed` (high) and `inferred` (medium) mappings are enqueued;
  # low-confidence (`tentative`) memberships are withheld and remain
  # reviewable through the preview summary.
  #
  # The backfill is idempotent and local-only. Idempotent: every row embeds
  # a deterministic idempotency key derived from the record's stable
  # observation timestamps, so reruns re-find stored rows, and rows
  # recreated after retention pruning reproduce the identical payload
  # TaskBridge Web already accepted (a replay, not a conflict). Local-only:
  # it reads sync_items/sync_collections and writes outbox rows; it never
  # contacts external source systems.
  class Baseline
    PUBLISHED_CONFIDENCES = %w[confirmed inferred].freeze
    UNKNOWN_CONFIDENCE = "unknown"

    def self.run!
      SyncBackfill::SourceProvenance.run!
      new.process(&:call)
    end

    # Same plan as run! but writes nothing — not even the source provenance
    # backfill — so it is a safe preview over production data.
    def self.preview
      new.process { nil }
    end

    def initialize(summary: Baseline::Summary.new)
      @summary = summary
    end

    # Yields one enqueue closure per planned row; the caller decides
    # whether rows are written (run!) or only counted (preview), so both
    # entry points share the exact same plan.
    def process(&)
      Base::SyncItem.find_each { |item| plan_item(item, &) }
      SyncCollection.includes(:sync_items).find_each { |collection| plan_collection(collection, &) }
      summary
    end

    private

    attr_reader :summary

    def plan_item(item)
      if item.external_id.blank?
        summary.skip_incomplete_item(service: service_type_for(item))
        return
      end

      summary.plan_item(service: service_type_for(item))
      yield -> { Outbox::ItemSnapshotEmitter.emit_for_item(item, observed_at: item_observed_at(item)) }
    end

    def plan_collection(collection)
      eligible, incomplete = collection.sync_items.partition { |member| member.external_id.present? }
      incomplete.each { summary.skip_incomplete_membership }
      return if eligible.empty?

      if publishable?(collection)
        eligible.each { |_member| summary.plan_membership(confidence: confidence_for(collection)) }
        yield -> { Outbox::MappingEmitter.emit_for_members(collection, members: eligible, observed_at: mapping_observed_at(collection)) }
      else
        eligible.each { |member| summary.withhold_membership(collection:, member:, confidence: confidence_for(collection)) }
      end
    end

    def publishable?(collection)
      PUBLISHED_CONFIDENCES.include?(confidence_for(collection))
    end

    def confidence_for(collection)
      Outbox::MappingEmitter.translated_confidence(collection.mapping_confidence).presence || UNKNOWN_CONFIDENCE
    end

    def service_type_for(item)
      Base::Service.service_identifier_for(item.provider)
    end

    # Same timestamp fallbacks SyncBackfill::SourceProvenance records, so a
    # run! after the provenance backfill reuses the stored observation time
    # and with it the same idempotency keys.
    def item_observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at || Time.current
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
    end
  end
end
