# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline item snapshots and confirmed/inferred mappings for TaskBridge Web (DRY_RUN=1 previews only)"
  task backfill_outbox: :environment do
    dry_run = ENV.fetch("DRY_RUN", "0") == "1"
    summary = SyncBackfill::OutboxBaseline.run!(dry_run:)
    puts JSON.generate(summary.deep_stringify_keys.merge("dry_run" => dry_run))
  end
end
