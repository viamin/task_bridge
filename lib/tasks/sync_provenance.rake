# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline TaskBridge Web outbox rows from existing sync data (DRY_RUN=1 previews only)"
  task backfill_outbox: :environment do
    SyncBackfill::Outbox.run!(dry_run: ENV["DRY_RUN"] == "1")
  end
end
