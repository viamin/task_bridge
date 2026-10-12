# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill provenance and baseline TaskBridge Web outbox snapshots (DRY_RUN=1 previews only)"
  task backfill_sync_provenance: :environment do
    report = SyncBackfill::Observations.run!(dry_run: ENV["DRY_RUN"] == "1")
    puts "Backfill item snapshots by service: #{report.fetch(:items_by_service).sort.to_h}"
    puts "Backfill mappings by confidence: #{report.fetch(:mappings_by_confidence).sort.to_h}"
    puts "Backfill skipped/incomplete: #{report.fetch(:skipped).sort.to_h}"
  end

  desc "alias for task_bridge:backfill_sync_provenance"
  task backfill_observations: :backfill_sync_provenance
end
