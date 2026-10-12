# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline item snapshots and confirmed/inferred mappings in the outbox (DRY_RUN=true previews only)"
  task backfill_observations: :environment do
    SyncBackfill::Observations.run!(dry_run: ENV["DRY_RUN"] == "true")
  end
end
