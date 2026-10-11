# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline TaskBridge Web outbox rows from existing sync data (DRY_RUN=1 reports only)"
  task backfill_outbox_baseline: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", false))
    report = SyncBackfill::OutboxBaseline.run!(dry_run:)
    puts JSON.generate(report.merge(dry_run:))
  end
end
