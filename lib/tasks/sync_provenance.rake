# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline item snapshots and confirmed/inferred sync mappings into the outbox"
  task backfill_outbox: :environment do
    puts SyncBackfill::OutboxSeed.run!.to_json
  end

  desc "preview the baseline outbox seed without changing local data"
  task backfill_outbox_dry_run: :environment do
    puts SyncBackfill::OutboxSeed.run!(dry_run: true).to_json
  end
end
