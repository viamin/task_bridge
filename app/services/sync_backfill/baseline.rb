# frozen_string_literal: true

module SyncBackfill
  # Backfills the outbox with baseline current-state rows (#222) so
  # TaskBridge Web can seed from known synchronized state and treat only
  # later published rows as change history (RDR #215, "Migration and
  # Backfill Implications"). Existing sync_items become one `item`
  # snapshot each — marked as baseline via provenance (detected_by
  # "backfill" plus backfilled_at), never as snapshot_seen observations —
  # and existing sync_collection memberships become `mapping` rows.
  #
  # Per the resolved RDR #215 open question, only confirmed and inferred
  # mappings are enqueued (high and medium confidence): low-confidence
  # memberships are withheld from the outbox and stay identifiable for
  # manual cleanup through this summary's confidence and method counts.
  # No sync_run rows are written — sync_service_states has no reliable
  # per-run start/end timestamps, so live sync runs publish them going
  # forward instead.
  #
  # The backfill only writes OutboxEntry rows: it never mutates external
  # source systems, never marks rows delivered, and is idempotent — every
  # row's idempotency key embeds a stable observed_at (the item's
  # last_observed_at / the collection's mapping_last_observed_at), so
  # rerunning re-finds stored rows instead of duplicating them.
  class Baseline
    # Confidences whose memberships are published; everything else (low
    # and unresolved "unknown") is withheld and only counted.
    PUBLISHABLE_CONFIDENCE = %w[high medium].freeze
    UNKNOWN = "unknown"

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    # Whether the #216/#217 provenance backfill still has work to do. The
    # dry-run task warns on this so operators do not mistake unresolved
    # provenance — counted as "unknown" and withheld — for final results.
    def self.provenance_pending?
      Base::SyncItem.where(last_observed_at: nil).exists? ||
        SyncCollection.where(mapping_method: nil).exists?
    end

    def self.format(summary)
      items = summary.fetch(:items)
      mappings = summary.fetch(:mappings)
      [
        "Baseline backfill#{' (dry run)' if summary[:dry_run]}:",
        "  items: #{items[:considered]} considered, #{items[:enqueued]} enqueued, " \
        "#{items[:skipped_incomplete]} skipped (no external id)",
        "  items by service: #{format_service_counts(items[:by_service])}",
        "  mappings: #{mappings[:collections]} collections, #{mappings[:memberships]} memberships, " \
        "#{mappings[:enqueued]} enqueued, #{mappings[:withheld_low_confidence]} withheld " \
        "(low confidence), #{mappings[:skipped_incomplete]} skipped (no external id)",
        "  mappings by confidence: #{format_counts(mappings[:by_confidence])}",
        "  mappings by method: #{format_counts(mappings[:by_method])}"
      ].join("\n")
    end

    def self.format_counts(counts)
      counts.map { |key, count| "#{key}=#{count}" }.join(", ")
    end

    def self.format_service_counts(counts)
      counts.map { |service, count| "#{service}=#{count[:enqueued]} enqueued/#{count[:skipped_incomplete]} skipped" }
            .join(", ")
    end
    private_class_method :format_counts, :format_service_counts

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
      @item_counts = Hash.new { |counts, service| counts[service] = { enqueued: 0, skipped_incomplete: 0 } }
      @items = { considered: 0, enqueued: 0, skipped_incomplete: 0 }
      @confidence_counts = Hash.new(0)
      @method_counts = Hash.new(0)
      @mappings = {
        collections: 0, memberships: 0, enqueued: 0,
        withheld_low_confidence: 0, skipped_incomplete: 0
      }
    end

    def run!
      backfill_items
      backfill_mappings
      {
        dry_run: dry_run?,
        items: @items.merge(by_service: @item_counts.sort.to_h),
        mappings: @mappings.merge(
          by_confidence: @confidence_counts.sort.to_h,
          by_method: @method_counts.sort.to_h
        )
      }
    end

    private

    attr_reader :now

    def dry_run?
      @dry_run
    end

    def backfill_items
      parents = parent_index
      Base::SyncItem.find_each do |item|
        @items[:considered] += 1
        service = Base::Service.service_identifier_for(item.provider)
        if item.external_id.blank?
          @items[:skipped_incomplete] += 1
          @item_counts[service][:skipped_incomplete] += 1
          next
        end

        enqueue_item_row(item, parents)
        @items[:enqueued] += 1
        @item_counts[service][:enqueued] += 1
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        @mappings[:collections] += 1
        backfill_collection(collection)
      end
    end

    def backfill_collection(collection)
      confidence = collection.mapping_confidence.presence || UNKNOWN
      mapping_method = collection.mapping_method.presence || UNKNOWN
      publishable = PUBLISHABLE_CONFIDENCE.include?(confidence)
      eligible_members = []

      collection.sync_items.each do |member|
        @mappings[:memberships] += 1
        if member.external_id.blank?
          @mappings[:skipped_incomplete] += 1
          next
        end

        @confidence_counts[confidence] += 1
        @method_counts[mapping_method] += 1
        if publishable
          eligible_members << member
        else
          @mappings[:withheld_low_confidence] += 1
        end
      end

      return if eligible_members.empty?

      @mappings[:enqueued] += eligible_members.size
      return if dry_run?

      Outbox::MappingEmitter.emit_for_members(
        collection,
        members: eligible_members,
        observed_at: mapping_observed_at(collection)
      )
    end

    def enqueue_item_row(item, parents)
      return if dry_run?

      row = ItemRow.new(
        item,
        backfilled_at: now,
        parent: parents[item.parent_item_id],
        sync_collection: collections_by_id[item.sync_collection_id]
      )
      Outbox::IsolatedWrite.call("baseline item for #{item.item_key}") do
        OutboxEntry.enqueue(record_kind: :item, payload: row.payload, **row.context)
      end
    end

    # Stable observation time for mapping rows so reruns reuse the same
    # idempotency keys; a later provenance upgrade advances
    # mapping_last_observed_at and correctly publishes a new mapping fact.
    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || now
    end

    def parent_index
      parent_ids = Base::SyncItem.where.not(parent_item_id: nil).distinct.pluck(:parent_item_id)
      Base::SyncItem.where(id: parent_ids).to_h do |parent|
        [parent.id, { external_id: parent.external_id, item_key: parent.item_key }]
      end
    end

    def collections_by_id
      @collections_by_id ||= SyncCollection.all.index_by(&:id)
    end
  end
end
