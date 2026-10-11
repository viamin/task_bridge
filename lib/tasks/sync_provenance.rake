# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline item snapshots and reliable mapping memberships (DRY_RUN=true previews only)"
  task backfill_outbox_baseline: :environment do
    summary = SyncBackfill::OutboxBaseline.run!(dry_run: ENV.fetch("DRY_RUN", "false") == "true")
    puts JSON.generate(summary)
  end
end
