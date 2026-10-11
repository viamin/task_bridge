# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed TaskBridge Web baseline snapshots and confirmed/inferred mappings (DRY_RUN=1 previews only)"
  task backfill_outbox_baseline: :environment do
    dry_run = ENV["DRY_RUN"] == "1"
    summary = SyncBackfill::OutboxBaseline.run!(dry_run:)
    puts "TaskBridge Web baseline backfill#{' dry run' if dry_run}: #{summary.inspect}"
  end
end
