# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill TaskBridge Web baseline snapshots and mapping metadata (DRY_RUN=true previews only)"
  task backfill_sync_data: :environment do
    dry_run = ENV["DRY_RUN"] == "true"
    summary = SyncBackfill::Baseline.run!(dry_run:)
    puts "Backfill#{' dry run' if dry_run}: #{summary.transform_values(&:to_h).to_json}"
  end

  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::Baseline.run!
  end
end
