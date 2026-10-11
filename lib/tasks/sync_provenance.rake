# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill provenance and baseline TaskBridge Web outbox snapshots (DRY_RUN=1 previews only)"
  task backfill_sync_provenance: :environment do
    runner = ENV["DRY_RUN"] == "1" ? SyncBackfill::Baseline.dry_run : SyncBackfill::Baseline.run!
    puts JSON.pretty_generate(runner)
  end
end
