# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill sync provenance and baseline TaskBridge Web outbox rows (BACKFILL_DRY_RUN=1 previews only)"
  task backfill_sync_provenance: :environment do
    dry_run = ENV["BACKFILL_DRY_RUN"] == "1"
    SyncBackfill::SourceProvenance.run! unless dry_run
    summary = SyncBackfill::Outbox.run!(dry_run:)
    puts "Backfill: #{summary.to_json}" unless dry_run
  end

  desc "backfill sync provenance and baseline TaskBridge Web outbox rows"
  task backfill_sync_data: :backfill_sync_provenance
end
