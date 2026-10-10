# frozen_string_literal: true

module SyncBackfill
  # Seeds baseline observations for existing synchronized data (#222): one
  # `snapshot_seen` row per persisted item the observation pipeline has
  # never observed, plus mapping rows for existing SyncCollection
  # memberships. Baseline rows state current state only — never historical
  # change events — so they carry `detected_by: "baseline_backfill"` with
  # observed_at pinned to the record's own observation timestamps. That
  # keeps each row's idempotency key deterministic, so reruns are safe
  # (RDR #215 backfill rules) and later `source_changed` rows remain true
  # history. Tentative mappings are withheld per the RDR's open-question
  # guidance and counted instead, so operators can review them before any
  # future policy change publishes them.
  #
  # The backfill is local-only: it reads sync_items/sync_collections and
  # writes outbox rows, never touching an external source system.
  class BaselineObservations
    DETECTED_BY = "baseline_backfill"
    # RDR #215 Open Questions: until the low-confidence mapping backfill
    # policy is decided, publish only `confirmed`/`inferred` mappings.
    PUBLISHABLE_CONFIDENCE = %w[confirmed inferred].freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run: false)
      @dry_run = dry_run
    end

    def run!
      { items: item_counts, mappings: mapping_counts }
    end

    private

    attr_reader :dry_run

    def item_counts
      counts = { "baseline" => 0, "skipped_incomplete" => 0,
                 "already_observed" => Base::SyncItem.where.not(last_snapshot: nil).count }
      by_service = Hash.new(0)
      Base::SyncItem.where(last_snapshot: nil).find_each do |item|
        if item.external_id.present?
          counts["baseline"] += 1
          by_service[service_type_of(item)] += 1
          emit_item_baseline(item) unless dry_run
        else
          counts["skipped_incomplete"] += 1
        end
      end
      counts.merge("by_service" => by_service.sort.to_h)
    end

    def emit_item_baseline(item)
      Outbox::ObservationEmitter.emit_for_item(
        item,
        previous_snapshot: nil,
        observed_at: baseline_observed_at(item),
        provenance: { "detected_by" => DETECTED_BY }
      )
    end

    # The moment TaskBridge last saw this item. Deterministic across reruns,
    # which keeps the baseline row's idempotency key stable even if a run is
    # interrupted after enqueueing but before the baseline advance.
    def baseline_observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_counts
      counts = { "published_members" => 0, "withheld_members" => 0, "skipped_incomplete_members" => 0 }
      withheld_collections = Hash.new(0)
      SyncCollection.includes(:sync_items).find_each do |collection|
        members = collection.sync_items.to_a
        eligible, incomplete = members.partition { |member| member.external_id.present? }
        counts["skipped_incomplete_members"] += incomplete.length
        next if eligible.empty?

        if publishable?(collection)
          counts["published_members"] += eligible.length
          emit_mapping_baseline(collection, eligible) unless dry_run
        else
          counts["withheld_members"] += eligible.length
          withheld_collections[withheld_confidence(collection)] += 1
        end
      end
      counts.merge("withheld_collections_by_confidence" => withheld_collections.sort.to_h)
    end

    def publishable?(collection)
      PUBLISHABLE_CONFIDENCE.include?(contract_confidence(collection))
    end

    # Translates the internal confidence vocabulary into the contract's,
    # using the same mapping the publisher rows will carry.
    def contract_confidence(collection)
      Outbox::MappingEmitter::CONFIDENCE.fetch(collection.mapping_confidence, collection.mapping_confidence)
    end

    def withheld_confidence(collection)
      collection.mapping_confidence.presence || "unmapped"
    end

    def emit_mapping_baseline(collection, members)
      Outbox::MappingEmitter.emit_for_members(
        collection,
        members:,
        observed_at: collection.mapping_last_observed_at || collection.updated_at || collection.created_at
      )
    end

    def service_type_of(item)
      Outbox::SourceIdentity.for(item)[:service_type]
    end
  end
end
