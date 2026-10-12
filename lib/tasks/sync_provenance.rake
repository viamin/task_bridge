# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline item snapshots and publishable mapping rows (DRY_RUN=true previews without writes)"
  task backfill_outbox: :environment do
    SyncBackfill::BaselineOutbox.run!(dry_run: ENV.fetch("DRY_RUN", "false") == "true")
  end
end
