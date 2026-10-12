# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "backfill baseline item snapshots and confirmed/inferred collection memberships into the outbox"
  task backfill_outbox_baseline: :environment do
    SyncBackfill::OutboxBaseline.run!(dry_run: ENV["DRY_RUN"] == "1")
  end
end
