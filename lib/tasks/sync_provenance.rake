# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline TaskBridge Web outbox snapshots and confirmed/inferred mappings (DRY_RUN=1 previews only)"
  task backfill_outbox: :environment do
    dry_run = ENV["DRY_RUN"].present?
    summary = SyncBackfill::OutboxSeeder.run!(dry_run:)
    puts "Backfill#{' dry run' if dry_run}: items=#{summary[:items]}, mappings=#{summary[:mappings]}, skipped=#{summary[:skipped]}"
  end
end
