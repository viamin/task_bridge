# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill provenance and baseline TaskBridge Web outbox snapshots"
  task backfill_sync_provenance: :environment do
    summary = SyncBackfill::SourceProvenance.run!(dry_run: ENV["DRY_RUN"] == "1")
    puts JSON.generate(summary)
  end

  desc "backfill baseline TaskBridge Web outbox snapshots (alias for backfill_sync_provenance)"
  task backfill_observations: :environment do
    Rake::Task["task_bridge:backfill_sync_provenance"].invoke
  end
end
