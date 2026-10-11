# frozen_string_literal: true

module SyncBackfill
  # Backfills the local outbox (#222) with a safe baseline of existing
  # synchronized data so TaskBridge Web can start from known current state
  # and only treat later diffs as change history (RDR #215 "Migration and
  # Backfill Implications").
  #
  # What it writes:
  # - one `item` snapshot row per existing sync_items row, marked as a
  #   baseline through provenance (`detected_by: "backfill"` plus
  #   `backfilled_at`), never as a historical change event — no
  #   `snapshot_seen` observation rows come from the backfill;
  # - one `mapping` row per existing SyncCollection membership, except
  #   low-confidence mappings, which are withheld from publication and
  #   surfaced in the dry-run summary for manual cleanup instead (explicit
  #   product decision point, resolved as RDR #215's safer default until
  #   the product owner decides how existing low-confidence mapping data
  #   should be handled);
  # - no `sync_run` rows: sync_service_states has no reliable per-run
  #   start/end timestamps and the RDR requires them.
  #
  # Idempotency: every row is keyed by a deterministic idempotency key built
  # from the record's own observation timestamps (never the backfill run
  # time), so rerunning finds the stored rows and enqueues nothing new.
  # The backfill only reads local tables and writes outbox rows (plus the
  # idempotent #218 provenance backfill as a prerequisite); it never
  # mutates external source systems.
  class OutboxBaseline
    # Internal (pre-translation) mapping confidences eligible for baseline
    # publication: `high` publishes as `confirmed`, `medium` (title-derived)
    # as `inferred`. Everything else — `low` and not-yet-backfilled nils —
    # is withheld.
    PUBLISHABLE_CONFIDENCE = %w[high medium].freeze

    # Provenance marker distinguishing backfilled baseline rows from live
    # observations in published payloads.
    DETECTED_BY = "backfill"

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    # Renders a summary hash (see #run!) as the operator-facing report the
    # rake tasks print.
    def self.render(summary)
      items = summary.fetch(:items)
      mappings = summary.fetch(:mappings)
      mode = summary.fetch(:dry_run) ? " (dry run — nothing written)" : ""
      <<~TEXT
        TaskBridge outbox baseline backfill#{mode}
        Items: #{items.fetch(:candidates)} candidates, #{items.fetch(:enqueued)} enqueued, \
        #{items.fetch(:already_present)} already present, #{items.fetch(:skipped_incomplete)} skipped (missing external id)
          By service: #{render_counts(items.fetch(:by_service))}
        Mappings: #{mappings.fetch(:collections)} collections, #{mappings.fetch(:enqueued)} enqueued, \
        #{mappings.fetch(:already_present)} already present, #{mappings.fetch(:withheld)} withheld (low confidence)
          By confidence: #{render_counts(mappings.fetch(:by_confidence))}
          #{render_withheld(mappings.fetch(:withheld_collections))}
      TEXT
    end

    def initialize(dry_run: false, now: Time.current)
      @dry_run = dry_run
      @now = now
      @summary = {
        dry_run:,
        items: {
          candidates: 0, enqueued: 0, already_present: 0, skipped_incomplete: 0,
          by_service: Hash.new(0)
        },
        mappings: {
          collections: 0, enqueued: 0, already_present: 0, withheld: 0,
          by_confidence: Hash.new(0), withheld_collections: []
        }
      }
    end

    def run!
      # Prerequisite (#218): fill identity/provenance fields first so every
      # row has a stable source identity and observation timestamps. Dry
      # runs skip it because it writes to sync_items/sync_collections.
      SyncBackfill::SourceProvenance.run! unless dry_run?
      backfill_item_snapshots
      backfill_collection_mappings
      summary
    end

    private

    attr_reader :now, :summary

    def dry_run?
      summary.fetch(:dry_run)
    end

    def backfill_item_snapshots
      Base::SyncItem.find_each do |item|
        items_summary[:candidates] += 1
        next tally_skipped_item(item) if item.external_id.blank?

        identity = Outbox::SourceIdentity.for(item)
        observed_at = item_observed_at(item)
        outcome = enqueue_or_tally(item_key(identity, observed_at)) do
          Outbox::ItemSnapshotEmitter.emit_for_item(item, observed_at:, detected_by: DETECTED_BY, backfilled_at: now)
        end
        items_summary[outcome] += 1
        items_summary[:by_service][identity[:service_type]] += 1
      end
    end

    def backfill_collection_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        mappings_summary[:collections] += 1
        members = collection.sync_items.select { |member| member.external_id.present? }
        next withhold(collection, members) unless publishable?(collection)

        observed_at = mapping_observed_at(collection)
        members.each do |member|
          identity = Outbox::SourceIdentity.for(member)
          outcome = enqueue_or_tally(mapping_key(identity, observed_at, collection.id)) do
            Outbox::MappingEmitter.emit_for_member(collection, member, observed_at:,
                                                                       detected_by: DETECTED_BY, backfilled_at: now)
          end
          mappings_summary[outcome] += 1
          mappings_summary[:by_confidence][translated_confidence(collection)] += 1
        end
      end
    end

    def item_key(identity, observed_at)
      Outbox::IdempotencyKey.for(
        record_kind: :item, observed_at:,
        service_instance: identity[:service_instance], external_id: identity[:external_id]
      )
    end

    def mapping_key(identity, observed_at, sync_collection_id)
      Outbox::IdempotencyKey.for(
        record_kind: :mapping, observed_at:, sync_collection_id:,
        service_instance: identity[:service_instance], external_id: identity[:external_id]
      )
    end

    # Returns :enqueued (created, or what a dry run would create) or
    # :already_present (a previous run's row stays untouched, keeping its
    # payload and delivery state immutable per RDR #215). Write errors
    # propagate: this is an operator-run task, and a failed run can simply
    # be rerun — already-written rows are found, not duplicated.
    def enqueue_or_tally(key)
      return :already_present if OutboxEntry.exists?(idempotency_key: key)
      return :enqueued if dry_run?

      yield
      :enqueued
    end

    def tally_skipped_item(item)
      items_summary[:skipped_incomplete] += 1
      warn "[#{self.class.name}] skipped #{item.class.name} ##{item.id}: missing external id"
    end

    def withhold(collection, members)
      mappings_summary[:withheld] += members.length
      return unless members.any?

      mappings_summary[:withheld_collections] << [collection.id, collection.title]
    end

    def publishable?(collection)
      collection.mapping_confidence.in?(PUBLISHABLE_CONFIDENCE)
    end

    def translated_confidence(collection)
      Outbox::MappingEmitter::CONFIDENCE.fetch(collection.mapping_confidence, collection.mapping_confidence)
    end

    # Deterministic per record, never per run: each fallback predates the
    # backfill itself, so reruns derive the same key and find the stored
    # row instead of duplicating it.
    def item_observed_at(item)
      item.last_observed_at || item.first_observed_at || item.updated_at || item.created_at || now
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.mapping_established_at || collection.updated_at || now
    end

    def items_summary
      summary.fetch(:items)
    end

    def mappings_summary
      summary.fetch(:mappings)
    end

    class << self
      private

      def render_counts(counts)
        return "none" if counts.blank?

        counts.sort.map { |name, count| "#{name}=#{count}" }.join(", ")
      end

      def render_withheld(collections)
        return "No low-confidence mappings withheld." if collections.blank?

        listing = collections.map { |id, title| %(##{id} "#{title}") }.join(", ")
        "Withheld low-confidence collections (review before cleanup): #{listing}"
      end
    end
  end
end
