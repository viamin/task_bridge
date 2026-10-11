# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill provenance, baseline item snapshots, and confirmed mapping rows"
  task backfill_sync_provenance: :environment do
    summary = if ENV["DRY_RUN"] == "true"
      SyncBackfill::BaselineOutbox.dry_run
    else
      SyncBackfill::BaselineOutbox.run!
    end
    puts JSON.pretty_generate(summary)
  end
end
