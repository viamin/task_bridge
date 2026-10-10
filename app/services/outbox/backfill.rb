# frozen_string_literal: true

module Outbox
  # Backfills the local outbox with a baseline of the data TaskBridge
  # already synchronizes (#222, RDR #215): one current-state `item`
  # snapshot per existing `sync_items` row and one `mapping` row per
  # `SyncCollection` membership. Baseline rows are marked as such in their
  # payload (`provenance.detected_by: "backfill"` plus `backfilled_at`)
  # rather than pretending to be historical change events — no
  # `snapshot_seen` observation rows and no `sync_run` rows are written;
  # live sync runs publish those going forward (#219-#221).
  #
  # The run is idempotent: every row's idempotency key is derived from
  # stable per-record timestamps (`last_observed_at` for items,
  # `mapping_last_observed_at` for mappings), so reruns re-detect the same
  # keys and `OutboxEntry.enqueue` returns the stored rows untouched. It
  # only writes local rows — publication stays gated behind the existing
  # `task_bridge.web.enabled` configuration — and never touches external
  # source systems. Dry runs write nothing and return the same summary
  # counts a real run reports.
  class Backfill
    DETECTED_BY = "backfill"
    MAPPING_TYPE = "representation_membership"
    MEMBERSHIP_ROLE = "member"

    # Backfill confidence translation (#222 clarified decision resolving
    # RDR #215's open question): `high` maps to `confirmed` and `medium`
    # maps to `inferred`; `low`-confidence memberships are withheld from
    # publication entirely and stay identifiable through the summary's
    # counts by confidence for manual cleanup or Web-side review.
    PUBLISHED_CONFIDENCE = {
      "high" => "confirmed",
      "medium" => "inferred"
    }.freeze

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run:, now: Time.current)
      @dry_run = dry_run
      @now = now
      @summary = {
        status: nil,
        items: new_bucket(%i[considered enqueued skipped dropped]),
        mappings: new_bucket(%i[memberships enqueued withheld skipped dropped]),
        by_confidence: Hash.new(0),
        skipped_reasons: Hash.new(0)
      }
    end

    def run!
      # Identity/provenance fields are the backfill's inputs (#216-#218),
      # so ensure they are complete first. The provenance backfill is
      # itself idempotent; a dry run skips it to stay write-free.
      SyncBackfill::SourceProvenance.run! unless dry_run?
      backfill_items
      backfill_collections
      finalize_summary
    end

    private

    attr_reader :now, :summary

    def dry_run?
      @dry_run
    end

    def backfill_items
      Base::SyncItem.includes(:sync_collection).find_each do |item|
        summary[:items][:considered] += 1
        next count_skipped_item(item) if item.external_id.blank?

        if dry_run?
          count_item(item, :enqueued)
        else
          count_item(item, enqueue_item(item))
        end
      end
    end

    def backfill_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        members = collection.sync_items.to_a
        summary[:mappings][:memberships] += members.length
        members.each { |member| record_member(collection, member) }
      end
    end

    def record_member(collection, member)
      confidence = collection.mapping_confidence.to_s
      summary[:by_confidence][confidence.presence || "unknown"] += 1
      return count_member(member, :skipped, "memberships_missing_mapping_confidence") if confidence.blank?
      return count_member(member, :skipped, "memberships_missing_external_id") if member.external_id.blank?
      return count_member(member, :withheld, "memberships_withheld_low_confidence") unless publishable?(confidence)

      dry_run? ? count_member(member, :enqueued) : count_member(member, enqueue_member(collection, member))
    end

    def enqueue_item(item)
      identity = Outbox::SourceIdentity.for(item)
      observed_at = item_observed_at(item)
      enqueue_row("backfill item for #{item.item_key}",
                  record_kind: :item,
                  payload: item_payload(item, observed_at),
                  **item_context(identity, item, observed_at))
    end

    def enqueue_member(collection, member)
      identity = Outbox::SourceIdentity.for(member)
      observed_at = collection_observed_at(collection)
      enqueue_row("backfill mapping for #{member.item_key}",
                  record_kind: :mapping,
                  payload: mapping_payload(collection, member, identity, observed_at),
                  **member_context(identity, collection, observed_at))
    end

    # Outbox writes are isolated per row (Outbox::IsolatedWrite): a dropped
    # row is reported in the summary and re-detected by rerunning the
    # idempotent backfill instead of aborting the whole run.
    def enqueue_row(description, record_kind:, payload:, **context)
      row = Outbox::IsolatedWrite.call(description) do
        OutboxEntry.enqueue(record_kind:, payload:, **context)
      end
      row.nil? ? :dropped : :enqueued
    end

    def item_payload(item, observed_at)
      snapshot = published_snapshot(item)
      payload = snapshot.except(:version, :metadata, :sync_collection_id).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        source_metadata: snapshot[:metadata],
        provenance: baseline_provenance
      )
      mapping_block = sync_collection_block(item.sync_collection)
      payload[:sync_collection] = mapping_block if mapping_block
      payload
    end

    def mapping_payload(collection, member, identity, observed_at)
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        mapping_type: MAPPING_TYPE,
        observed_at: iso_timestamp(observed_at),
        sync_collection: {
          sync_collection_id: collection.id,
          title: collection.title
        },
        member: identity.merge(item_key: member.item_key),
        membership_role: MEMBERSHIP_ROLE,
        mapping_confidence: PUBLISHED_CONFIDENCE.fetch(collection.mapping_confidence.to_s),
        mapping_source: mapping_source_for(collection),
        provenance: baseline_provenance.merge(
          method: collection.mapping_method,
          confidence: collection.mapping_confidence,
          metadata: collection.mapping_metadata
        )
      }
    end

    def item_context(identity, item, observed_at)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
    end

    def member_context(identity, collection, observed_at)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: collection.id,
        observed_at:
      }
    end

    # Baseline membership facts are only asserted on item snapshots when
    # the mapping is publishable; a withheld low-confidence mapping must
    # not reach TaskBridge Web through the snapshot either.
    def sync_collection_block(collection)
      return if collection.nil? || !publishable?(collection.mapping_confidence.to_s)

      {
        sync_collection_id: collection.id,
        membership_role: MEMBERSHIP_ROLE,
        mapping_confidence: PUBLISHED_CONFIDENCE.fetch(collection.mapping_confidence.to_s),
        mapping_source: mapping_source_for(collection)
      }
    end

    def publishable?(confidence)
      PUBLISHED_CONFIDENCE.key?(confidence)
    end

    def mapping_source_for(collection)
      Outbox::MappingEmitter::SOURCE.fetch(collection.mapping_method.to_s, collection.mapping_method)
    end

    # Baseline provenance markers (#222): the row states current data as
    # first observed by this backfill, not a historical change event.
    # Extra payload fields are safe because v1 consumers must ignore
    # unknown fields (RDR #215).
    def baseline_provenance
      { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(now) }
    end

    # The stored/published snapshot form: identical to normalized_snapshot
    # but with timestamps rendered as ISO 8601 UTC (see
    # Outbox::ObservationEmitter#published_snapshot).
    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    # Stable per-item observation time so reruns derive the same
    # idempotency key; `last_observed_at` is maintained by the provenance
    # backfill that just ran.
    def item_observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at || now
    end

    def collection_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || now
    end

    def count_item(item, outcome)
      summary[:items][outcome] += 1
      item_services[item.service_key][outcome] += 1
    end

    def count_skipped_item(item)
      summary[:skipped_reasons]["items_missing_external_id"] += 1
      count_item(item, :skipped)
    end

    def count_member(member, outcome, reason = nil)
      summary[:mappings][outcome] += 1
      mapping_services[member.service_key][outcome] += 1
      summary[:skipped_reasons][reason] += 1 if reason
    end

    def new_bucket(keys)
      keys.index_with(0)
    end

    def finalize_summary
      summary[:status] = dry_run? ? "dry_run" : "completed"
      summary[:items][:by_service] = sorted_nested(item_services)
      summary[:mappings][:by_service] = sorted_nested(mapping_services)
      summary[:mappings][:by_confidence] = sorted_flat(summary[:by_confidence])
      summary[:skipped_reasons] = sorted_flat(summary[:skipped_reasons])
      summary.except(:by_confidence).deep_dup
    end

    def sorted_nested(counts)
      counts.transform_values { |outcomes| sorted_flat(outcomes) }.sort.to_h
    end

    def sorted_flat(counts)
      counts.sort.to_h
    end

    def item_services
      @item_services ||= Hash.new { |hash, key| hash[key] = Hash.new(0) }
    end

    def mapping_services
      @mapping_services ||= Hash.new { |hash, key| hash[key] = Hash.new(0) }
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
