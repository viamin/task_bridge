# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill baseline outbox snapshots, mappings, and source provenance (DRY_RUN=1 previews only)"
  task backfill_sync_provenance: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", false))
    summary = SyncBackfill::Baseline.run!(dry_run:)
    puts "Sync backfill#{' dry run' if dry_run}: #{summary.to_json}"
  end
end
