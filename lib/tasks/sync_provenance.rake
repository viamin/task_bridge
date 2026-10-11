# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline item snapshots and publishable mapping memberships for TaskBridge Web (DRY_RUN=1 previews only)"
  task backfill_observation_baseline: :environment do
    dry_run = ENV["DRY_RUN"] == "1"
    SyncBackfill::SourceProvenance.run!(dry_run:)
    summary = SyncBackfill::ObservationBaseline.run!(dry_run:)
    puts JSON.pretty_generate(summary)
  end
end
