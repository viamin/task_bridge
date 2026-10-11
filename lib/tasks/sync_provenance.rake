# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "backfill baseline snapshots and confirmed/inferred mappings into the local outbox"
  task backfill_outbox_baseline: :environment do
    dry_run = ENV.fetch("DRY_RUN", "false") == "true"
    SyncBackfill::OutboxBaseline.run!(dry_run:)
  end
end
