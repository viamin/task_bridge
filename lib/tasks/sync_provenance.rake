# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill TaskBridge Web baseline snapshots and sync mapping provenance"
  task backfill_sync_provenance: :environment do
    summary = SyncBackfill::SourceProvenance.run!
    puts "Backfilled #{summary[:items].values.sum} item snapshots; considered #{summary[:mappings].values.sum} mapping memberships"
  end

  desc "preview TaskBridge Web baseline backfill counts without writing data"
  task backfill_sync_provenance_dry_run: :environment do
    summary = SyncBackfill::SourceProvenance.run!(dry_run: true)
    puts JSON.generate(summary)
  end
end
