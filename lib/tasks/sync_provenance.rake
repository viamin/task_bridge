# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline item snapshots and reliable mapping rows (DRY_RUN=1 reports without writes)"
  task backfill_outbox: :environment do
    dry_run = ENV["DRY_RUN"] == "1"
    summary = SyncBackfill::Baseline.run!(dry_run:)
    puts JSON.generate(summary.merge(dry_run:))
  end
end
