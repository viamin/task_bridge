# frozen_string_literal: true

module Outbox
  # Backfills existing TaskBridge data into the local outbox as baseline
  # current state (issue #222; RDR #215 "Migration and Backfill
  # Implications") so TaskBridge Web can start from a known state and treat
  # only later diffs as change history.
  #
  # What it generates:
  # - one `item` snapshot row per existing sync item, marked as baseline
  #   via payload provenance (`detected_by: "backfill"` plus
  #   `backfilled_at`) rather than pretending to be a historical change
  #   event — no `snapshot_seen` observation rows come from the backfill;
  # - `mapping` rows for existing SyncCollection memberships whose
  #   confidence publishes as `confirmed` (high) or `inferred` (medium).
  #     Low-confidence/tentative memberships are withheld from publication
  #   (resolved RDR #215 open question) and stay identifiable through the
  #   dry-run summary counts by confidence for manual cleanup or Web-side
  #   review.
  #
  # Safety:
  # - idempotent: row identity is deterministic because observed_at comes
  #   from the timestamps already stored on the rows, never the run clock,
  #   so reruns re-find their own outbox rows;
  # - local only: nothing in the backfill mutates external source systems;
  # - write mode first runs SyncBackfill::SourceProvenance (itself
  #   idempotent) so identity/provenance and mapping metadata exist before
  #   anything is published.
  class Backfill
    DETECTED_BY = "backfill"

    # Internal mapping confidences (SyncCollection#mapping_confidence)
    # eligible for backfill publication: `high` publishes as `confirmed`
    # and `medium` as `inferred` (Outbox::MappingEmitter::CONFIDENCE).
    # Everything else — `low`/`tentative`, or rows with no recorded
    # confidence — is withheld and counted in the summary.
    PUBLISHABLE_CONFIDENCE = %w[high medium].freeze

    def self.run!
      new(CommitWriter.new).generate
    end

    def self.dry_run
      new(NullWriter.new).generate
    end

    # Renders a summary hash (see Summary#to_h) as operator-facing lines.
    def self.format_summary(summary)
      items = summary.fetch(:items)
      mappings = summary.fetch(:mappings)
      mode = summary.fetch(:dry_run) ? "dry run (nothing was written)" : "complete"
      [
        "Outbox backfill #{mode}:",
        "  item snapshots: #{items[:enqueued]} enqueued, #{items[:skipped]} skipped/incomplete",
        *items[:by_service].sort.map { |service, counts| service_line(service, counts) },
        "  mapping memberships: #{mappings[:enqueued]} enqueued, #{mappings[:withheld]} withheld",
        *mappings[:by_confidence].sort.map { |confidence, counts| confidence_line(confidence, counts) }
      ].join("\n")
    end

    def self.service_line(service, counts)
      "    #{service}: #{counts[:enqueued]} enqueued, #{counts[:skipped]} skipped/incomplete"
    end

    def self.confidence_line(confidence, counts)
      "    #{confidence}: #{counts[:enqueued]} enqueued, #{counts[:withheld]} withheld"
    end

    attr_reader :writer, :summary

    def initialize(writer, summary: Summary.new)
      @writer = writer
      @summary = summary
    end

    def generate
      writer.prepare
      generate_item_rows
      generate_mapping_rows
      summary.to_h(dry_run: writer.dry_run?)
    end

    private

    def generate_item_rows
      # Base::SyncItem is the STI base, so this walks every service's rows
      # and instantiates each under its own type.
      Base::SyncItem.find_each do |item|
        identity = Outbox::SourceIdentity.for(item)
        if identity[:external_id].blank?
          summary.record_item(identity[:service_type], enqueued: false)
          next
        end

        observed_at = item_observed_at(item)
        writer.enqueue_item(item_payload(item), item:, identity:, observed_at:)
        summary.record_item(identity[:service_type], enqueued: true)
      end
    end

    def generate_mapping_rows
      SyncCollection.includes(:sync_items).find_each do |collection|
        members = eligible_members(collection)
        publishable = publishable?(collection)
        summary.record_memberships(collection.mapping_confidence,
                                   enqueued: publishable ? members.count : 0,
                                   withheld: publishable ? 0 : members.count)
        next unless publishable

        writer.enqueue_members(collection, members:, observed_at: mapping_observed_at(collection))
      end
    end

    def eligible_members(collection)
      # Mirrors Outbox::MappingEmitter's eligibility (persisted sync items
      # with an external id) without duplicating its row shape: the emitter
      # re-filters, and members that cannot be published are counted as
      # skipped items by the item pass above.
      collection.sync_items.select { |member| member.external_id.present? }
    end

    def publishable?(collection)
      PUBLISHABLE_CONFIDENCE.include?(collection.mapping_confidence)
    end

    # The published baseline snapshot: the item's normalized snapshot with
    # timestamps rendered as ISO 8601 UTC (the same published form the live
    # observation emitter stores), plus the baseline provenance that marks
    # the row as a backfill fact rather than a historical change event.
    # Extra fields beyond the contract's minimum are safe: version 1
    # consumers must ignore unknown fields.
    def item_payload(item, backfilled_at: Time.current)
      snapshot = item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? value.utc.iso8601(6) : value
      end
      snapshot.delete(:version)
      snapshot[:contract_version] = OutboxEntry::PAYLOAD_VERSION
      snapshot[:source_metadata] = snapshot.delete(:metadata)
      snapshot[:provenance] = {
        detected_by: DETECTED_BY,
        backfilled_at: backfilled_at.utc.iso8601(6)
      }
      snapshot
    end

    # Deterministic observed_at keeps idempotency keys stable across
    # reruns: keys embed observed_at, so the backfill reuses the timestamps
    # already stored on the rows instead of the run clock.
    def item_observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at || Time.current
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
    end

    # Writes real outbox rows.
    class CommitWriter
      def prepare
        # Capture identity/provenance fields and mapping metadata first so
        # rows publish with their strongest known identity.
        SyncBackfill::SourceProvenance.run!
      end

      def dry_run?
        false
      end

      def enqueue_item(payload, item:, identity:, observed_at:)
        OutboxEntry.enqueue(
          record_kind: :item,
          payload:,
          service_type: identity[:service_type],
          service_instance: identity[:service_instance],
          external_id: identity[:external_id],
          sync_collection_id: item.sync_collection_id,
          source_updated_at: item.source_updated_at || item.last_modified,
          observed_at:
        )
      end

      def enqueue_members(collection, members:, observed_at:)
        Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at:)
      end
    end

    # Computes the identical summary without writing anything.
    class NullWriter
      def prepare; end

      def dry_run?
        true
      end

      def enqueue_item(*); end

      def enqueue_members(*); end
    end

    # Accumulates backfill counts for operator review: item snapshots by
    # service, mapping memberships by confidence (withheld low-confidence
    # memberships included), and totals.
    class Summary
      def initialize
        @items_by_service = Hash.new { |hash, key| hash[key] = { enqueued: 0, skipped: 0 } }
        @memberships_by_confidence = Hash.new { |hash, key| hash[key] = { enqueued: 0, withheld: 0 } }
      end

      def record_item(service_type, enqueued:)
        key = enqueued ? :enqueued : :skipped
        items_by_service[service_type][key] += 1
      end

      def record_memberships(confidence, enqueued:, withheld:)
        bucket = memberships_by_confidence[confidence.to_s.presence || "unknown"]
        bucket[:enqueued] += enqueued
        bucket[:withheld] += withheld
      end

      def to_h(dry_run:)
        {
          dry_run:,
          items: {
            total: items_by_service.values.sum { |counts| counts.values.sum },
            enqueued: items_by_service.values.sum { |counts| counts[:enqueued] },
            skipped: items_by_service.values.sum { |counts| counts[:skipped] },
            by_service: items_by_service
          },
          mappings: {
            memberships: memberships_by_confidence.values.sum { |counts| counts.values.sum },
            enqueued: memberships_by_confidence.values.sum { |counts| counts[:enqueued] },
            withheld: memberships_by_confidence.values.sum { |counts| counts[:withheld] },
            by_confidence: memberships_by_confidence
          }
        }
      end

      private

      attr_reader :items_by_service, :memberships_by_confidence
    end
  end
end
