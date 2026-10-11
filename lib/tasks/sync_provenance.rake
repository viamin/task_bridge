# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline item snapshots and eligible mapping memberships in the outbox (DRY_RUN=true prints counts only)"
  task backfill_outbox: :environment do
    dry_run = ENV.fetch("DRY_RUN", "false").casecmp?("true")
    summary = SyncBackfill::Outbox.run!(dry_run:)
    puts JSON.generate(summary)
  end
end
