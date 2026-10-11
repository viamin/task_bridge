# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill provenance plus baseline item and mapping outbox rows (DRY_RUN=1 previews only)"
  task backfill_sync_provenance: :environment do
    SyncBackfill::Baseline.run!(dry_run: ENV["DRY_RUN"] == "1")
  end
end
