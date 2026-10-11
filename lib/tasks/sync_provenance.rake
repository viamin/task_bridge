# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "backfill baseline TaskBridge Web snapshots and confirmed mappings (DRY_RUN=1 previews only)"
  task backfill_outbox: :environment do
    dry_run = ENV.fetch("DRY_RUN", "0") == "1"
    result = SyncBackfill::Baseline.run!(dry_run:)
    puts "Backfill #{dry_run ? 'dry run' : 'complete'}"
    puts "Item snapshots by service: #{result.items_by_service.sort.to_h}"
    puts "Mappings by confidence: #{result.mappings_by_confidence.sort.to_h}"
    puts "Skipped/incomplete: #{result.skipped.sort.to_h}"
  end
end
