# frozen_string_literal: true

namespace :task_bridge do
  namespace :outbox do
    desc "backfill current item snapshots and confirmed/inferred mappings (DRY_RUN=true previews only)"
    task backfill: :environment do
      dry_run = ENV.fetch("DRY_RUN", "false").casecmp?("true")
      summary = SyncBackfill::OutboxBaseline.run!(dry_run:)
      puts JSON.generate(summary)
    end
  end
end
