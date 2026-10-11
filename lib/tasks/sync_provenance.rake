# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "backfill baseline item snapshots and confirmed/inferred mapping rows (DRY_RUN=1 to preview)"
  task backfill_observation_baseline: :environment do
    summary = SyncBackfill::ObservationBaseline.run!(dry_run: ENV["DRY_RUN"] == "1")
    puts JSON.generate(summary)
  end
end
