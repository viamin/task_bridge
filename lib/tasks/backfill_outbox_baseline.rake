# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill baseline item snapshot and mapping rows into the outbox for existing sync data"
  task backfill_outbox_baseline: :environment do
    summary = SyncBackfill::OutboxBaseline.run!
    puts "Outbox baseline backfill complete: #{summary.to_json}"
  end

  desc "preview the outbox baseline backfill without writing any rows"
  task backfill_outbox_baseline_dry_run: :environment do
    summary = SyncBackfill::OutboxBaseline.run!(dry_run: true)
    puts "Outbox baseline backfill dry run (no rows written): #{summary.to_json}"
  end
end
