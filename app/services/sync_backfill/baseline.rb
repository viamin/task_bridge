# frozen_string_literal: true

module SyncBackfill
  # Enqueues the TaskBridge Web baseline (#222) for sync data that already
  # exists locally: one current-state `item` snapshot per known sync item
  # and one `mapping` row per SyncCollection membership TaskBridge Web is
  # allowed to see. Baseline rows are marked as initial observations —
  # provenance.detected_by "backfill" plus backfilled_at — and never as
  # historical change events: the backfill emits no snapshot_seen or
  # source_changed observations and no sync-run summaries (RDR #215
  # "Migration and Backfill Implications", clarified under #222).
  #
  # Everything is derived from the local database; providers are never
  # contacted, so the backfill cannot mutate external source systems. The
  # prerequisite identity/mapping provenance pass
  # (SyncBackfill::SourceProvenance) only fills local columns and is a
  # no-op once populated.
  #
  # Reruns are safe. Item rows are seeded once per source identity: rows
  # whose identity already has an item record are skipped and counted, so
  # live syncs re-observing items between runs never trigger a second
  # baseline wave. Mapping rows rely on deterministic idempotency keys
  # over stable collection timestamps, and OutboxEntry.enqueue never
  # rewrites a stored row, so repeated runs neither duplicate rows nor
  # mutate already-enqueued payloads.
  #
  # Low-confidence memberships are withheld rather than published
  # (clarified under #222, resolving RDR #215's open backfill question):
  # only high/confirmed and medium/inferred mappings are enqueued.
  # Withheld memberships stay reviewable through the dry-run summary's
  # counts by confidence and through SyncCollection.mapping_confidence
  # locally; once an operator upgrades a collection's provenance, the next
  # run publishes it.
  class Baseline
    DETECTED_BY = "backfill"
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze
    # The dry run iterates every planned row for its counts but performs no
    # writes, so it drains generation through this no-op consumer.
    NO_OP = ->(_row) {}

    class << self
      def run!
        new.execute
      end

      # Plans every row without writing anything (the provenance pass is
      # skipped too): same counts a real run would produce, so operators
      # can preview the baseline before enabling publication.
      def dry_run
        new.plan
      end

      def format_summary(summary)
        items = summary.fetch(:items)
        mappings = summary.fetch(:mappings)
        verb = summary[:dry_run] ? "would enqueue" : "enqueued"
        [
          "Baseline backfill#{' (dry run)' if summary[:dry_run]} at #{summary.fetch(:backfilled_at).utc.iso8601(6)}",
          "Items: #{items[:enqueued]} #{verb} (#{render_counts(items[:by_service])}); " \
          "#{items[:already_backfilled]} already backfilled; " \
          "#{total(items[:skipped_incomplete])} skipped incomplete (#{render_counts(items[:skipped_incomplete])})",
          "Mappings: #{mappings[:enqueued]} of #{mappings[:memberships]} memberships #{verb} " \
          "across #{mappings[:collections]} collections (#{render_counts(mappings[:by_confidence])}); " \
          "#{total(mappings[:withheld_by_confidence])} withheld " \
          "(#{render_counts(mappings[:withheld_by_confidence])}); " \
          "#{mappings[:skipped_incomplete]} skipped incomplete"
        ].join("\n")
      end

      private

      def render_counts(counts)
        return "none" if counts.blank?

        counts.sort.map { |key, count| "#{key}: #{count}" }.join(", ")
      end

      def total(counts)
        counts.values.sum
      end
    end

    def initialize
      @backfilled_at = Time.current
      @summary = default_summary
    end

    attr_reader :summary

    # Ensures the prerequisite provenance exists, then enqueues every
    # planned row. Transient outbox write failures are isolated per row
    # (Outbox::IsolatedWrite): a dropped row is reported and a rerun
    # re-attempts it.
    def execute
      SyncBackfill::SourceProvenance.run!
      generate { |row| enqueue(row) }
      summary
    end

    def plan
      generate(&NO_OP)
      summary.merge(dry_run: true)
    end

    private

    attr_reader :backfilled_at

    def generate(&)
      generate_item_rows(&)
      generate_mapping_rows(&)
    end

    def generate_item_rows(&)
      Base::SyncItem.find_each do |item|
        generate_item_row(item, &)
      end
    end

    def generate_item_row(item)
      summary[:items][:considered] += 1
      return record_incomplete_item(item) if item.external_id.blank?

      identity = Outbox::SourceIdentity.for(item)
      if backfilled_identities.include?(identity_key(identity))
        summary[:items][:already_backfilled] += 1
        return
      end

      summary[:items][:enqueued] += 1
      summary[:items][:by_service][identity[:service_type]] += 1
      yield item_row(item, identity)
    end

    def record_incomplete_item(item)
      service_type = Base::Service.service_identifier_for(item.provider)
      summary[:items][:skipped_incomplete][service_type] += 1
    end

    def generate_mapping_rows(&)
      SyncCollection.includes(:sync_items).find_each do |collection|
        generate_collection_rows(collection, &)
      end
    end

    def generate_collection_rows(collection, &)
      summary[:mappings][:collections] += 1
      confidence = effective_confidence(collection)
      collection.sync_items.each do |member|
        generate_membership_row(collection, member, confidence, &)
      end
    end

    def generate_membership_row(collection, member, confidence)
      return summary[:mappings][:skipped_incomplete] += 1 unless Outbox::MappingEmitter.eligible?(member)

      summary[:mappings][:memberships] += 1
      unless publishable?(confidence)
        key = confidence.presence || "unknown"
        return summary[:mappings][:withheld_by_confidence][key] += 1
      end

      summary[:mappings][:enqueued] += 1
      summary[:mappings][:by_confidence][Outbox::MappingEmitter.contract_confidence_for(confidence)] += 1
      yield mapping_row(collection, member)
    end

    def item_row(item, identity)
      observed_at = observed_at_for(item)
      {
        record_kind: :item,
        payload: item_payload(item, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
    end

    def item_payload(item, observed_at)
      # The published snapshot form: normalized_snapshot with timestamps
      # rendered as ISO 8601 UTC so JSON round-trips keep microsecond
      # precision (mirrors Outbox::ObservationEmitter#published_snapshot),
      # marked as baseline rather than as a change event.
      serialize_snapshot(item).merge(
        observed_at: iso_timestamp(observed_at),
        provenance: baseline_provenance
      )
    end

    def serialize_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def mapping_row(collection, member)
      Outbox::MappingEmitter.row_for(
        collection, member,
        observed_at: mapping_observed_at(collection),
        provenance_extras: baseline_provenance
      )
    end

    def baseline_provenance
      { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(backfilled_at) }
    end

    def enqueue(row)
      Outbox::IsolatedWrite.call("baseline #{row[:record_kind]} for #{row[:service_instance]}:#{row[:external_id]}") do
        OutboxEntry.enqueue(**row)
      end
    end

    # Mirrors the timestamps SyncBackfill::SourceProvenance records so a
    # dry run plans (and a rerun reuses) the facts the provenance pass
    # establishes.
    def observed_at_for(item)
      item.last_observed_at || item.updated_at || item.created_at || backfilled_at
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || backfilled_at
    end

    # The confidence the provenance pass has established (or, for a dry
    # run on not-yet-backfilled data, the one it would establish).
    def effective_confidence(collection)
      collection.mapping_confidence.presence ||
        SyncBackfill::SourceProvenance.inferred_provenance_for(collection).fetch(:confidence)
    end

    def publishable?(confidence)
      PUBLISHABLE_CONFIDENCES.include?(confidence)
    end

    def backfilled_identities
      @backfilled_identities ||= OutboxEntry.where(record_kind: "item")
                                            .pluck(:service_type, :service_instance, :external_id).to_set
    end

    def identity_key(identity)
      [identity[:service_type], identity[:service_instance], identity[:external_id]]
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end

    def default_summary
      {
        dry_run: false,
        backfilled_at: backfilled_at,
        items: {
          considered: 0,
          enqueued: 0,
          already_backfilled: 0,
          by_service: Hash.new(0),
          skipped_incomplete: Hash.new(0)
        },
        mappings: {
          collections: 0,
          memberships: 0,
          enqueued: 0,
          by_confidence: Hash.new(0),
          withheld_by_confidence: Hash.new(0),
          skipped_incomplete: 0
        }
      }
    end
  end
end
