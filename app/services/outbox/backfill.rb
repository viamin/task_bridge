# frozen_string_literal: true

module Outbox
  # Backfills the outbox (#222) with baseline rows for data that existed
  # before the observation pipeline shipped (#216-#221): one current-state
  # `item` snapshot per existing sync item and `mapping` rows for existing
  # SyncCollection memberships. Per RDR #215 these rows are baseline
  # observations of current state — marked `provenance.detected_by:
  # "backfill"` with a `backfilled_at` timestamp — never historical change
  # events; TaskBridge Web treats later diffs as change history on top of
  # this known state. No `sync_run` or `observation` rows are written:
  # sync_service_states has no reliable per-run timestamps (#222
  # clarification) and `snapshot_seen` discovery belongs to the live
  # pipeline (#219).
  #
  # Idempotency: identities already carrying an outbox row are skipped, and
  # every idempotency key is derived from a stable per-record timestamp
  # (last_observed_at for items, mapping_last_observed_at for collections —
  # both pinned by SyncBackfill::SourceProvenance, which runs first) rather
  # than the wall clock, so reruns neither duplicate rows nor resubmit a
  # fact under a different key.
  #
  # Mapping confidence policy (#222 clarification, resolving RDR #215's
  # open question): backfill publishes only `confirmed` (high) and
  # `inferred` (medium) memberships. `low`-confidence memberships are
  # withheld from publication and remain identifiable through the summary
  # counts by confidence for manual cleanup or Web-side review.
  #
  # The backfill only writes local rows; it never contacts external source
  # systems. Run it before enabling TaskBridge Web publication (#221) so
  # the first publication carries the baseline (see
  # docs/backfill-outbox-baseline.md).
  class Backfill
    DETECTED_BY = "backfill"
    PUBLISHED_CONFIDENCES = %w[high medium].freeze
    WITHHELD_CONFIDENCE = "low"
    UNKNOWN_CONFIDENCE = "unknown"

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run: false)
      @dry_run = dry_run
      @summary = Summary.new(dry_run:)
    end

    def run!
      # Identity/provenance fields first (#218) so every existing row has
      # source identity, observation timestamps, and mapping confidence
      # before baseline rows are derived from them. Skipped in dry run so
      # the preview stays read-only; the dry run hydrates the same
      # resolution in memory instead.
      SyncBackfill::SourceProvenance.run! unless dry_run
      backfill_items
      backfill_collections
      summary
    end

    private

    attr_reader :dry_run, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        hydrate_item_identity(item)
        if item.external_id.blank?
          summary.count_item(:skipped_incomplete)
          next
        end

        identity = Outbox::SourceIdentity.for(item)
        summary.count_item_service(identity[:service_type])
        if existing_item_identities.include?(identity_tuple(identity))
          summary.count_item(:existing)
          next
        end
        next summary.count_item(:enqueued) if dry_run

        entry = enqueue_item_snapshot(item, identity)
        # A nil entry can only mean enqueue was skipped under --pretend;
        # count it as enqueued so the summary still adds up.
        summary.count_item(entry.nil? || entry.previously_new_record? ? :enqueued : :existing)
      end
    end

    def enqueue_item_snapshot(item, identity)
      observed_at = item_observed_at(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def backfill_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = resolved_confidence(collection)
        complete, incomplete = collection.sync_items.to_a.partition { |member| member.external_id.present? }
        summary.count_memberships(complete.length + incomplete.length)
        summary.count_mapping(:skipped_incomplete, incomplete.length)
        summary.count_membership_confidence(confidence, complete.length)
        next unless publish_confidence?(confidence)

        emit_collection_members(collection, complete)
      end
    end

    def emit_collection_members(collection, members)
      observed_at = collection_observed_at(collection)
      pending, existing = members.partition do |member|
        !existing_memberships.include?(membership_tuple(collection, member))
      end
      summary.count_mapping(:existing, existing.length)
      return summary.count_mapping(:enqueued, pending.length) if dry_run

      entries = Outbox::MappingEmitter.emit_for_members(
        collection, members: pending, observed_at:,
                    provenance: { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(observed_at) }
      )
      summary.count_mapping(:enqueued, entries.count(&:previously_new_record?))
      summary.count_mapping(:existing, entries.count { |entry| !entry.previously_new_record? })
    end

    def publish_confidence?(confidence)
      PUBLISHED_CONFIDENCES.include?(confidence)
    end

    def resolved_confidence(collection)
      return collection.mapping_confidence.presence || UNKNOWN_CONFIDENCE unless infer_confidence?(collection)

      SyncBackfill::SourceProvenance.provenance_for(collection).fetch(:confidence, UNKNOWN_CONFIDENCE)
    end

    # The real run infers and persists missing mapping provenance through
    # SyncBackfill::SourceProvenance before reading confidences; the dry
    # run (which skips that write) computes the same inference in memory.
    def infer_confidence?(collection)
      dry_run && collection.mapping_method.blank?
    end

    # Dry-run stand-in for the identity half of
    # SyncBackfill::SourceProvenance#backfill_sync_items: resolves the
    # service name (from peer sync-id notes where possible) on the
    # in-memory record so counts by service preview what the real run
    # would persist. Never saved.
    def hydrate_item_identity(item)
      return unless dry_run && item.source_service_name.blank?

      item.source_service_name = Base::SyncItem.inferred_service_name_for(item)
      item.source_service_instance = Base::Service.instance_name_for(item.source_service_name)
    end

    def item_payload(item, observed_at)
      item.normalized_snapshot
          .deep_transform_values { |value| value.respond_to?(:utc) ? iso_timestamp(value) : value }
          .merge(
            contract_version: OutboxEntry::PAYLOAD_VERSION,
            observed_at: iso_timestamp(observed_at),
            provenance: baseline_provenance(observed_at)
          )
    end

    def baseline_provenance(observed_at)
      # Pinning backfilled_at to the record's stable observed_at keeps
      # payloads byte-identical on rerun, honoring the RDR #215 rule that
      # a resubmitted idempotency key must carry the same canonical payload.
      { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(observed_at) }
    end

    def item_observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at
    end

    def collection_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def existing_item_identities
      @existing_item_identities ||= OutboxEntry.where(record_kind: "item")
                                               .pluck(:service_type, :service_instance, :external_id).to_set
    end

    def existing_memberships
      @existing_memberships ||= OutboxEntry.where(record_kind: "mapping")
                                           .pluck(:sync_collection_id, :service_type, :service_instance, :external_id)
                                           .to_set
    end

    def identity_tuple(identity)
      [identity[:service_type], identity[:service_instance], identity[:external_id]]
    end

    def membership_tuple(collection, member)
      identity = Outbox::SourceIdentity.for(member)
      [collection.id, identity[:service_type], identity[:service_instance], identity[:external_id]]
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
