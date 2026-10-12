# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline item snapshots and confident mappings into the outbox (DRY_RUN=1 previews only)"
  task backfill_outbox: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", false))
    summary = SyncBackfill::OutboxBaseline.run!(dry_run:)
    mode = dry_run ? "would enqueue" : "enqueued"
    puts "Outbox baseline #{mode}: #{summary.sort.to_h.to_json}"
  end
end
