# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed TaskBridge Web baseline item and confirmed mapping outbox rows (DRY_RUN=1 previews only)"
  task backfill_task_bridge_web: :environment do
    SyncBackfill::TaskBridgeWeb.run!(dry_run: ENV["DRY_RUN"] == "1")
  end
end
