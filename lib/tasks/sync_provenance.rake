# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed TaskBridge Web's outbox with current-state baseline snapshots and confirmed mappings"
  task backfill_outbox_baseline: :environment do
    SyncBackfill::OutboxBaseline.run!(dry_run: ENV.fetch("DRY_RUN", "false") == "true")
  end
end
