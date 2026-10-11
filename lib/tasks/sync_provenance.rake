# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline item snapshots and confirmed/inferred mappings into the outbox"
  task backfill_outbox: :environment do
    puts JSON.generate(SyncBackfill::OutboxSeed.run!)
  end

  desc "report the outbox baseline backfill without changing TaskBridge data"
  task backfill_outbox_dry_run: :environment do
    puts JSON.generate(SyncBackfill::OutboxSeed.preview)
  end
end
