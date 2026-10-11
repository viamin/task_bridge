# frozen_string_literal: true

module Outbox
  # Seeds the local outbox with the baseline rows TaskBridge Web needs to
  # start from known current state (issue #222; RDR #215, "Migration and
  # Backfill Implications"): one current-state `item` snapshot per existing
  # sync item and one `mapping` row per publishable SyncCollection
  # membership. Baseline rows are marked with backfill provenance
  # (`provenance.detected_by: "backfill"` plus a `backfilled_at` timestamp)
  # so they are never mistaken for historical change events, and the run is
  # safe to repeat: deterministic idempotency keys and a rerun skip over
  # already-queued source identities mean unchanged data enqueues nothing.
  #
  # Per #222's resolved clarifications: no `snapshot_seen` observation rows
  # and no `sync_run` rows come from the backfill — live sync runs publish
  # those going forward; low/unknown-confidence memberships are withheld
  # from publication and surfaced through the dry-run summary instead.
  # The backfill only writes OutboxEntry rows (and seeds each item's diff
  # baseline); it never contacts external source systems.
  class Backfill
    DETECTED_BY = "backfill"
    # RDR #215's open low-confidence question, resolved for #222: publish
    # only `confirmed` (high) and `inferred` (medium) mappings; withhold
    # low-confidence and unlabelled ones for manual/Web-side review.
    PUBLISHABLE_CONFIDENCE = %w[high medium].freeze
    UNKNOWN_CONFIDENCE = "unknown"

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
      @summary = Summary.new(dry_run:)
    end

    def run!
      backfill_item_snapshots
      backfill_mappings
      summary
    end

    private

    attr_reader :now, :summary

    def dry_run?
      @dry_run
    end

    def backfill_item_snapshots
      Base::SyncItem.find_each do |item|
        identity = Outbox::SourceIdentity.for(item)
        service_type = identity[:service_type]
        if item.external_id.blank?
          summary.count_item(service_type, :skipped)
          next
        end
        next if backfilled_item_identities.include?(identity_key(identity))

        observed_at = item.last_observed_at || item.updated_at
        baseline = baseline_snapshot(item, observed_at)
        row = enqueue(
          record_kind: :item,
          payload: baseline.merge(
            contract_version: OutboxEntry::PAYLOAD_VERSION,
            provenance: { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(now) }
          ),
          **item_context(item, identity, observed_at)
        )
        summary.count_item(service_type, row ? :enqueued : :skipped)
        seed_diff_baseline(item, baseline)
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence.presence || UNKNOWN_CONFIDENCE
        collection.sync_items.each do |member|
          if member.external_id.blank?
            summary.count_mapping(confidence, :skipped)
            next
          end
          next if backfilled_mapping_identities.include?(mapping_key(collection, member))

          if publishable?(confidence)
            row = enqueue_mapping(collection, member)
            summary.count_mapping(confidence, row ? :enqueued : :skipped)
          else
            summary.count_mapping(confidence, :withheld)
            summary.record_withheld_member(collection:, member:, confidence:)
          end
        end
      end
    end

    # Unlike the emitters' IsolatedWrite swallowing, a backfill runs on
    # operator command: a failed write aborts with a clear trace, and a
    # rerun completes the remaining rows safely. Dry runs write nothing —
    # they return a truthy marker so counts still reflect what a real run
    # would enqueue.
    def enqueue(record_kind:, payload:, **context)
      return :dry_run if dry_run?

      OutboxEntry.enqueue(record_kind:, payload:, **context)
    end

    def enqueue_mapping(collection, member)
      payload, context = Outbox::MappingEmitter.row_for(
        collection, member,
        observed_at: mapping_observed_at(collection), detected_by: DETECTED_BY
      )
      enqueue(record_kind: :mapping, payload:, **context)
    end

    # Seeds each item's stored diff baseline so the next live refresh only
    # publishes later diffs instead of re-discovering every backfilled item
    # (the "safe baseline" the observation pipeline starts from). Never
    # clobbers a baseline the live pipeline already stored.
    def seed_diff_baseline(item, baseline)
      return if dry_run? || item.last_snapshot.present?

      item.update_column(:last_snapshot, baseline)
    end

    def item_context(item, identity, observed_at)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
    end

    # The published and baseline form of the snapshot: identical to
    # normalized_snapshot but with timestamps rendered as ISO 8601 UTC so
    # JSON round-trips keep microsecond precision and stay diff-stable.
    def baseline_snapshot(item, observed_at)
      item.normalized_snapshot
          .deep_transform_values { |value| value.respond_to?(:utc) ? iso_timestamp(value) : value }
          .merge(observed_at: iso_timestamp(observed_at))
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at
    end

    def publishable?(confidence)
      PUBLISHABLE_CONFIDENCE.include?(confidence)
    end

    # The outbox is a bounded queue (retention windows prune delivered and
    # terminal rows), so existing baseline identities fit in memory; one
    # bulk pluck per record kind keeps the backfill free of N+1 lookups.
    def backfilled_item_identities
      @backfilled_item_identities ||= OutboxEntry.where(record_kind: "item")
                                                 .pluck(:service_type, :service_instance, :external_id).to_set
    end

    def backfilled_mapping_identities
      @backfilled_mapping_identities ||= OutboxEntry.where(record_kind: "mapping")
                                                    .pluck(:sync_collection_id, :service_instance, :external_id).to_set
    end

    def identity_key(identity)
      [identity[:service_type], identity[:service_instance], identity[:external_id]]
    end

    def mapping_key(collection, member)
      identity = Outbox::SourceIdentity.for(member)
      [collection.id, identity[:service_instance], identity[:external_id]]
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
