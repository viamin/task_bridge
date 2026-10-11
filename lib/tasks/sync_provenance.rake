# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline item snapshots and confirmed/inferred mappings into the outbox (DRY_RUN=1 previews only)"
  task backfill_sync_observations: :environment do
    SyncBackfill::OutboxSeed.run!(dry_run: ENV.fetch("DRY_RUN", "0") == "1")
  end
end
