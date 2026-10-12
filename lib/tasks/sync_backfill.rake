# frozen_string_literal: true

namespace :task_bridge do
  desc "seed baseline item snapshots and confirmed/inferred mappings (DRY_RUN=1 previews without writes)"
  task backfill_observations: :environment do
    SyncBackfill::ObservationBaseline.run!(dry_run: ENV["DRY_RUN"] == "1")
  end
end
