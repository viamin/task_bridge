# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed TaskBridge Web outbox with baseline current state (DRY_RUN=1 previews without writes)"
  task backfill_observation_baseline: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", false))
    SyncBackfill::SourceProvenance.run! unless dry_run
    summary = SyncBackfill::BaselineOutbox.run!(dry_run:)
    puts JSON.generate(summary.merge(dry_run:))
  end
end
