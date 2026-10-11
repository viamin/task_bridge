# frozen_string_literal: true

module SyncBackfill
  # Generates the baseline outbox rows (#222) for data TaskBridge already
  # synchronizes, so TaskBridge Web can start from known current state and
  # only treat later diffs as change history (RDR #215 "Migration and
  # Backfill Implications"). Idempotent by construction: every row's
  # idempotency key is derived from stable, item-derived timestamps — never
  # from the wall clock of the run — so rerunning the backfill re-finds the
  # stored rows instead of duplicating them.
  #
  # Per the product decisions recorded on #222:
  # * one `item` snapshot row per existing sync item, marked as baseline via
  #   `provenance.detected_by: "backfill"` and `backfilled_at`; no
  #   `snapshot_seen` observation rows are written by the backfill;
  # * mapping rows only for memberships at `confirmed`/`inferred` confidence
  #   (`high`/`medium`); `low`/`tentative` memberships are withheld from
  #   publication and listed in the dry-run summary instead;
  # * no `sync_run` rows: `sync_service_states` holds no reliable per-run
  #   start/end timestamps, and the RDR only allows backfilled sync-run
  #   summaries where reliable timestamps exist.
  #
  # The backfill is write-local only: it never instantiates a provider
  # service, so it can never mutate an external source system, and it never
  # publishes — rows stay pending in the outbox until
  # `rake task_bridge:outbox:publish` sends them.
  class OutboxBaseline
    DETECTED_BY = "backfill"

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run: false)
      @dry_run = dry_run
      @summary = Summary.new(dry_run:)
    end

    def run!
      backfill_items
      backfill_collections
      summary
    end

    private

    attr_reader :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        backfill_item(item)
      rescue StandardError => e
        # One unadaptable record (e.g. an adapter whose metadata needs the
        # transient external payload) must not abort the whole backfill;
        # report it as incomplete and keep going.
        warn "[#{self.class.name}] skipping #{item.item_key}: #{e.class}: #{e.message}"
        summary.skip_item(reason: "snapshot_failed")
      end
    end

    def backfill_item(item)
      if item.external_id.blank?
        summary.skip_item(reason: "missing_external_id")
        return
      end

      identity = Outbox::SourceIdentity.for(item)
      observed_at = item.last_observed_at || item.updated_at || item.created_at
      snapshot = serialize_snapshot(item)
      if enqueue_item_snapshot(item, identity:, snapshot:, observed_at:)
        summary.enqueue_item(service_type: identity[:service_type])
        store_diff_baseline(item, snapshot:)
      else
        summary.skip_item(reason: "write_failed")
      end
    end

    def backfill_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        members, ineligible_count = partition_members(collection)
        summary.skip_memberships(ineligible_count)

        if Outbox::MappingEmitter.publishable_confidence?(collection.mapping_confidence)
          enqueue_memberships(collection, members)
        else
          summary.withhold_memberships(members.length, confidence: collection.mapping_confidence)
        end
      end
    end

    def enqueue_item_snapshot(item, identity:, snapshot:, observed_at:)
      return true if dry_run?

      Outbox::IsolatedWrite.call("baseline item snapshot for #{item.item_key}") do
        OutboxEntry.enqueue(
          record_kind: :item,
          payload: item_payload(snapshot:, observed_at:),
          service_type: identity[:service_type],
          service_instance: identity[:service_instance],
          external_id: identity[:external_id],
          observed_at:,
          source_updated_at: item.source_updated_at || item.last_modified
        )
      end
    end

    # Baseline current state, not a historical change event: the payload is
    # the item's normalized snapshot (Base::SnapshotSerializer) with
    # timestamps rendered ISO for JSON stability, plus backfill markers v1
    # consumers safely ignore until they learn them.
    def item_payload(snapshot:, observed_at:)
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: observed_at.utc.iso8601(6),
        provenance: { detected_by: DETECTED_BY },
        backfilled_at: observed_at.utc.iso8601(6)
      )
    end

    def enqueue_memberships(collection, members)
      return summary.enqueue_memberships(members.length, confidence: collection.mapping_confidence) if dry_run?

      observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at
      Outbox::MappingEmitter.emit_for_members(
        collection,
        members:,
        observed_at:,
        baseline: { detected_by: DETECTED_BY, backfilled_at: observed_at }
      )
      summary.enqueue_memberships(members.length, confidence: collection.mapping_confidence)
    end

    # Seed the live pipeline's diff baseline (#219) so the next refresh of a
    # pre-existing item emits only later changes instead of re-publishing a
    # discovery `snapshot_seen`. Written only after the snapshot row was
    # enqueued, and never clobbering a baseline a live sync already stored.
    def store_diff_baseline(item, snapshot:)
      return if dry_run? || item.read_attribute(:last_snapshot).present?

      item.update_column(:last_snapshot, snapshot)
    end

    def partition_members(collection)
      eligible, ineligible = collection.sync_items.to_a.partition do |member|
        member.external_id.present?
      end
      [eligible, ineligible.length]
    end

    # Same published form as Outbox::ObservationEmitter#published_snapshot:
    # normalized_snapshot with timestamps as ISO 8601 UTC so JSON
    # round-trips keep microsecond precision and stay diff-stable.
    def serialize_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? value.utc.iso8601(6) : value
      end
    end

    def dry_run?
      @dry_run == true
    end

    # Mutable counters for one run, reported by service and confidence so
    # operators (and the dry run) can see exactly what the backfill would
    # publish, withhold, and skip (#222 acceptance criteria). Withheld
    # low-confidence memberships are identifiable here because publication
    # intentionally omits them.
    class Summary
      attr_reader :items_by_service, :skipped_items_by_reason,
                  :memberships_by_confidence, :withheld_by_confidence, :ineligible_memberships

      def initialize(dry_run: false)
        @dry_run = dry_run
        @items_by_service = Hash.new(0)
        @skipped_items_by_reason = Hash.new(0)
        @memberships_by_confidence = Hash.new(0)
        @withheld_by_confidence = Hash.new(0)
        @ineligible_memberships = 0
      end

      def enqueue_item(service_type:)
        items_by_service[service_type] += 1
      end

      def skip_item(reason:)
        skipped_items_by_reason[reason] += 1
      end

      def enqueue_memberships(count, confidence:)
        memberships_by_confidence[confidence_label(confidence)] += count
      end

      def withhold_memberships(count, confidence:)
        withheld_by_confidence[confidence_label(confidence)] += count
      end

      def skip_memberships(count)
        @ineligible_memberships += count
      end

      def to_h
        {
          dry_run: @dry_run,
          items_by_service: items_by_service.transform_keys(&:to_s),
          skipped_items_by_reason: skipped_items_by_reason.transform_keys(&:to_s),
          memberships_by_confidence: memberships_by_confidence.transform_keys(&:to_s),
          withheld_memberships_by_confidence: withheld_by_confidence.transform_keys(&:to_s),
          ineligible_memberships:
        }
      end

      def to_s
        <<~TEXT
          Baseline backfill#{' (dry run — nothing was written)' if @dry_run}:
            item snapshots by service: #{labeled_counts(items_by_service)}
            skipped items by reason: #{labeled_counts(skipped_items_by_reason)}
            mapping memberships by confidence: #{labeled_counts(memberships_by_confidence)}
            withheld memberships by confidence: #{labeled_counts(withheld_by_confidence)}
            memberships skipped as incomplete: #{ineligible_memberships}
        TEXT
      end

      private

      def confidence_label(confidence)
        confidence.presence || "unknown"
      end

      def labeled_counts(counts)
        return "none" if counts.empty?

        counts.sort_by { |label, _| label.to_s }.map { |label, count| "#{label}=#{count}" }.join(", ")
      end
    end
  end
end
