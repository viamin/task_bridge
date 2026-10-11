# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "backfill baseline TaskBridge Web outbox snapshots and confirmed mappings (DRY_RUN=1 previews only)"
  task backfill_outbox_baseline: :environment do
    SyncBackfill::OutboxBaseline.run!(dry_run: ENV.fetch("DRY_RUN", "0") == "1")
  end
end
