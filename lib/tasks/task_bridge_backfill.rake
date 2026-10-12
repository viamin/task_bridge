# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill baseline item snapshots and mapping rows for existing sync data " \
       "(see docs/taskbridge-web-baseline-backfill.md; idempotent, safe to rerun)"
  task backfill_baseline_observations: :environment do
    dry_run = ENV["DRY_RUN"] == "1"
    summary = SyncBackfill::Runner.run!(dry_run:)
    if dry_run
      puts "Baseline backfill dry-run finished; nothing was written to the outbox."
    else
      puts "Baseline backfill complete: #{summary[:items_emitted]} items, " \
           "#{summary[:mappings_emitted]} mappings, " \
           "#{summary[:memberships_withheld_low_confidence]} low-confidence memberships withheld."
    end
  end
end
