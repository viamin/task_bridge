# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "backfill baseline TaskBridge Web snapshots and confirmed mappings (DRY_RUN=true previews without writes)"
  task backfill_outbox: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", false))
    summary = SyncBackfill::Outbox.run!(dry_run:)
    puts summary.sort.to_h.to_json
  end
end
