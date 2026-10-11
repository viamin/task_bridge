# frozen_string_literal: true

namespace :task_bridge do
  namespace :outbox do
    desc "backfill baseline item snapshots and mapping rows into the outbox for existing sync data"
    task backfill_baseline: :environment do
      puts SyncBackfill::Baseline.run!.format
      puts "Run task_bridge:outbox:publish (or the dry-run task first) to deliver the baseline to TaskBridge Web"
    end

    desc "preview the baseline backfill without writing anything (counts by service and confidence, lists withheld mappings)"
    task backfill_baseline_dry_run: :environment do
      puts SyncBackfill::Baseline.preview.format
      warn "Baseline dry run: nothing was written, nothing was sent"
    end
  end
end
