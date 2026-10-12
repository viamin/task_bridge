# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline TaskBridge Web snapshots and confirmed mappings (DRY_RUN=1 previews only)"
  task backfill_taskbridge_web: :environment do
    SyncBackfill::OutboxBaseline.run!(dry_run: ENV["DRY_RUN"].present?)
  end
end
