# frozen_string_literal: true

module SyncBackfill
  # Entry point for the #222 outbox backfill: baseline item snapshots plus
  # confirmed/inferred mapping rows for existing `sync_items` and
  # `sync_collections`. Does not run SyncBackfill::SourceProvenance itself
  # — that backfill must be run first (it is the identity/provenance
  # source this one reads) — see docs/backfill-outbox-baseline.md for the
  # full operational sequence, including why dry runs never touch the
  # database.
  module ObservationBackfill
    module_function

    def run!(dry_run: false)
      {
        items: BaselineSnapshots.run!(dry_run:),
        mappings: MappingObservations.run!(dry_run:)
      }
    end
  end
end
