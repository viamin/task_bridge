# frozen_string_literal: true

module SyncBackfill
  # Seeds the local outbox with baseline rows for sync data that existed
  # before observation publication shipped (RDR #215 "Migration and
  # Backfill Implications", issue #222) so TaskBridge Web can start from
  # the known current state and only treat later diffs as change history.
  #
  # The backfill is write-local only — it reads `sync_items` and
  # `sync_collections` and never contacts an external source system — and
  # it is idempotent:
  #
  # - item snapshot rows are keyed by the item's stable last_observed_at,
  #   and each backfilled item stores the published snapshot as its diff
  #   baseline (`last_snapshot`), so reruns skip items the live pipeline
  #   (#219) or an earlier backfill already covered;
  # - mapping rows reuse the deterministic RDR #215 idempotency keys, so
  #   reruns re-find the same rows instead of duplicating them.
  #
  # Baseline rows are marked as such (`provenance.detected_by: "backfill"`
  # plus `backfilled_at`) rather than presented as historical change
  # events: the backfill emits item snapshots and mapping rows only — no
  # `snapshot_seen` observations and no `sync_run` summaries, which only
  # live sync runs produce (#222 clarification).
  #
  # Mapping publication policy (#222 clarification, resolving RDR #215's
  # open question): `high` publishes as `confirmed`, `medium` as
  # `inferred`; `low`-confidence memberships are withheld from publication
  # entirely and only appear in the summary counts by confidence, where
  # they stay identifiable for manual cleanup.
  class OutboxBaseline
    DETECTED_BY = "backfill"
    PUBLISHED_CONFIDENCES = %w[high medium].freeze
    WITHHELD_CONFIDENCE = "low"

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
      @summary = Summary.new
    end

    def run!
      # Idempotent prerequisite (#218): fills source identity, first/last
      # observed, and mapping provenance so rows publish with full
      # identity. A dry run must write nothing, so it skips this and
      # computes the same provenance read-only instead.
      SyncBackfill::SourceProvenance.run! unless dry_run?
      backfill_items
      backfill_collections
      summary.report(dry_run: dry_run?)
    end

    private

    attr_reader :now, :summary

    def dry_run?
      @dry_run
    end

    def backfill_items
      Base::SyncItem.preload(:sync_collection).find_each { |item| process_item(item) }
    end

    def process_item(item)
      return summary.skip_item(:missing_sti_type) if item.instance_of?(Base::SyncItem)
      return summary.skip_item(:missing_external_id) if item.external_id.blank?
      return summary.count_item(service_type_of(item), :already_observed) if item.last_snapshot.present?
      return summary.count_item(service_type_of(item), :enqueued) if dry_run?

      if enqueue_item_snapshot(item)
        summary.count_item(service_type_of(item), :enqueued)
      else
        summary.skip_item(:write_failed)
      end
    end

    # Enqueues the baseline item snapshot and records it as the item's diff
    # baseline only after the row is safely stored, so an abandoned write
    # is retried by the next run (at-least-once, like the live emitter).
    def enqueue_item_snapshot(item)
      snapshot = published_snapshot(item)
      row = Outbox::IsolatedWrite.call("backfill item snapshot for #{item.item_key}") do
        OutboxEntry.enqueue(
          record_kind: :item,
          payload: item_payload(item, snapshot),
          **enqueue_context(item)
        )
      end
      item.update_column(:last_snapshot, snapshot) if row
      row
    end

    def item_payload(item, snapshot)
      snapshot
        .merge(
          contract_version: OutboxEntry::PAYLOAD_VERSION,
          observed_at: iso_timestamp(observed_at_for(item)),
          provenance: { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(now) }
        )
        .then do |payload|
          # `metadata` is the local snapshot's name for the contract's
          # source-specific `source_metadata` block.
          payload[:source_metadata] = payload.delete(:metadata)
          payload[:sync_collection] = membership_payload(item) if publishable_collection?(item.sync_collection)
          payload
        end
    end

    def enqueue_context(item)
      identity = Outbox::SourceIdentity.for(item)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: observed_at_for(item)
      }
    end

    # The membership block is omitted for low-confidence collections so a
    # withheld mapping never leaks into TaskBridge Web through the item
    # snapshot; publishable memberships are also stated as mapping rows.
    def membership_payload(item)
      collection = item.sync_collection
      {
        sync_collection_id: collection.id,
        membership_role: Outbox::MappingEmitter::MEMBERSHIP_ROLE,
        mapping_confidence: Outbox::MappingEmitter::CONFIDENCE.fetch(collection.mapping_confidence, collection.mapping_confidence),
        mapping_source: Outbox::MappingEmitter::SOURCE.fetch(collection.mapping_method, collection.mapping_method)
      }
    end

    def publishable_collection?(collection)
      collection.present? && PUBLISHED_CONFIDENCES.include?(collection.mapping_confidence)
    end

    def observed_at_for(item)
      item.last_observed_at || item.updated_at || item.created_at
    end

    # Identical to the live emitter's stored baseline shape: the normalized
    # snapshot with every timestamp rendered as ISO 8601 UTC so JSON
    # round-trips keep microsecond precision and stay diff-stable.
    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def service_type_of(item)
      Outbox::SourceIdentity.for(item)[:service_type]
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end

    def backfill_collections
      existing_keys = OutboxEntry.where(record_kind: "mapping")
                                 .pluck(:sync_collection_id, :idempotency_key)
                                 .each_with_object(Hash.new { |hash, id| hash[id] = Set.new }) do |(id, key), hash|
        hash[id] << key
      end
      SyncCollection.includes(:sync_items).find_each do |collection|
        process_collection(collection, existing_keys[collection.id])
      end
    end

    def process_collection(collection, existing_keys)
      members = collection.sync_items.to_a
      confidence = effective_confidence(collection)
      unless PUBLISHED_CONFIDENCES.include?(confidence)
        members.each { |member| count_withheld(member) }
        return
      end

      observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at
      members.each do |member|
        process_member(collection, member, confidence, observed_at, existing_keys)
      end
    end

    def process_member(collection, member, confidence, observed_at, existing_keys)
      return skip_ineligible_member(member) unless eligible_member?(member)

      return summary.count_mapping(service_type_of(member), confidence, :existing) if existing_keys.include?(mapping_key(member, collection, observed_at))
      return summary.count_mapping(service_type_of(member), confidence, :enqueued) if dry_run?

      rows = Outbox::MappingEmitter.emit_for_members(
        collection, members: [member], observed_at:, backfilled_at: now
      )
      rows.any? ? summary.count_mapping(service_type_of(member), confidence, :enqueued) : summary.skip_mapping(:write_failed)
    end

    def eligible_member?(member)
      !member.instance_of?(Base::SyncItem) && member.external_id.present?
    end

    def mapping_key(member, collection, observed_at)
      identity = Outbox::SourceIdentity.for(member)
      Outbox::IdempotencyKey.for(
        record_kind: :mapping,
        observed_at:,
        sync_collection_id: collection.id,
        service_instance: identity[:service_instance],
        external_id: identity[:external_id]
      )
    end

    # What mapping confidence the collection carries for this run: the
    # stored provenance once materialized (always the case in real runs,
    # which run SourceProvenance first), or the same inference computed
    # read-only during a dry run. Blank confidence withholds.
    def effective_confidence(collection)
      return collection.mapping_confidence.presence || WITHHELD_CONFIDENCE if collection.mapping_method.present?

      SyncBackfill::SourceProvenance.new.inferred_provenance_for(collection)[:confidence] || WITHHELD_CONFIDENCE
    end

    def count_withheld(member)
      return skip_ineligible_member(member) unless eligible_member?(member)

      summary.count_mapping(service_type_of(member), WITHHELD_CONFIDENCE, :withheld)
    end

    def skip_ineligible_member(member)
      reason = member.instance_of?(Base::SyncItem) ? :missing_sti_type : :missing_external_id
      summary.skip_mapping(reason)
    end
  end
end
