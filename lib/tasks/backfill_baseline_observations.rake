# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill baseline item snapshot and mapping outbox rows for existing sync data " \
       "(writes outbox rows; run task_bridge:backfill_sync_provenance first; safe to rerun)"
  task backfill_baseline_observations: :environment do
    print_baseline_backfill_summary(SyncBackfill::BaselineObservations.run!)
  end

  desc "preview the baseline item snapshot and mapping outbox rows without writing any of them"
  task backfill_baseline_observations_dry_run: :environment do
    print_baseline_backfill_summary(SyncBackfill::BaselineObservations.run!(dry_run: true), dry_run: true)
  end

  def print_baseline_backfill_summary(summary, dry_run: false)
    prefix = dry_run ? "[dry run] " : ""
    items = summary.fetch(:items)
    mappings = summary.fetch(:mappings)
    puts "#{prefix}Item snapshots: #{items[:enqueued]} enqueued, " \
         "#{items[:skipped_incomplete]} skipped (incomplete identity), by service: #{items[:by_service]}"
    puts "#{prefix}Mapping memberships: #{mappings[:enqueued]} enqueued, " \
         "#{mappings[:withheld_low_confidence]} withheld (low confidence), " \
         "#{mappings[:skipped_incomplete]} skipped (incomplete mapping), " \
         "by confidence: #{mappings[:by_confidence]}, by service: #{mappings[:by_service]}"
  end
end
