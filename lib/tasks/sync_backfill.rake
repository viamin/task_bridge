# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill baseline item snapshots and confirmed/inferred mapping memberships (DRY_RUN=1 previews only)"
  task backfill_observations: :environment do
    SyncBackfill::Baseline.run!(dry_run: ENV.fetch("DRY_RUN", "0") == "1")
  end
end
