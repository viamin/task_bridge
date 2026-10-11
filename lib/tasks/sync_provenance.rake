# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill source provenance, baseline item snapshots, and publishable mapping memberships"
  task backfill_sync_provenance: :environment do
    dry_run = ENV.fetch("DRY_RUN", "false").casecmp?("true")
    summary = SyncBackfill::OutboxBaseline.run!(dry_run:)
    puts JSON.generate(summary)
  end
end
