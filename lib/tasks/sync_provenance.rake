# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline item snapshots and confirmed/inferred mappings (DRY_RUN=1 previews without writes)"
  task backfill_outbox: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", false))
    summary = SyncBackfill::Outbox.run!(dry_run:)
    puts JSON.pretty_generate(summary)
  end
end
