# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "backfill TaskBridge Web baseline snapshots and known mappings (DRY_RUN=1 previews only)"
  task backfill_outbox: :environment do
    dry_run = ENV.fetch("DRY_RUN", "0") == "1"
    report = SyncBackfill::Outbox.run!(dry_run:)
    puts JSON.generate(report.deep_stringify_keys)
  end
end
