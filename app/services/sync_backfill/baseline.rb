# frozen_string_literal: true

module SyncBackfill
  # Backfills the outbox baseline (#222, RDR #215 "Migration and Backfill
  # Implications") so TaskBridge Web can start from the known current
  # state of existing sync data and treat only later rows as change
  # history:
  #
  # - refreshes sync item/collection provenance first
  #   (SyncBackfill::SourceProvenance, #216-#218);
  # - enqueues one baseline `item` snapshot per existing sync item, marked
  #   as baseline via provenance (no `snapshot_seen` observation rows);
  # - enqueues `mapping` rows for existing SyncCollection memberships,
  #   withholding low-confidence memberships per the clarified decision
  #   on #222 (they stay identifiable through the summary's withheld
  #   counts by confidence and method);
  # - writes no `sync_run` rows: sync_service_states has no reliable
  #   per-run start/end timestamps and the RDR requires them.
  #
  # The backfill only writes local rows (item/collection provenance and
  # outbox entries); it never contacts providers or TaskBridge Web and
  # never mutates external source systems. Dry runs write nothing at all
  # and preview exactly the rows a real run would enqueue.
  class Baseline
    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def self.identity_for(item)
      effective_service_name = item.source_service_name.presence ||
                               Base::SyncItem.inferred_service_name_for(item)
      # In-memory only: a real run persists these through
      # SyncBackfill::SourceProvenance before enumerating, so assigning
      # them here lets a dry run preview the exact identities (and
      # idempotency keys) a real run produces for legacy rows.
      item.source_service_name = effective_service_name
      item.source_service_instance = Base::Service.instance_name_for(effective_service_name) if item.source_service_instance.blank?
      Outbox::SourceIdentity.for(item)
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
    end

    def run!
      provenance = refresh_provenance
      facts = MappingFacts.for_all_collections
      items = ItemSnapshots.run!(dry_run: @dry_run, backfilled_at: @now, collection_facts: facts)
      mappings = Mappings.run!(dry_run: @dry_run, backfilled_at: @now, facts:)
      Summary.new(dry_run: @dry_run, provenance:, items:, mappings:)
    end

    private

    def refresh_provenance
      incomplete_items = Base::SyncItem.where(last_observed_at: nil).count
      incomplete_collections = SyncCollection.where(mapping_method: nil).count
      return { items_backfilled: 0, collections_backfilled: 0 } if @dry_run

      SyncBackfill::SourceProvenance.run!
      {
        items_backfilled: incomplete_items - Base::SyncItem.where(last_observed_at: nil).count,
        collections_backfilled: incomplete_collections - SyncCollection.where(mapping_method: nil).count
      }
    end
  end
end
