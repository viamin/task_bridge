# frozen_string_literal: true

namespace :task_bridge do
  namespace :backfill_baseline_observations do
    desc "preview baseline item snapshot and mapping outbox rows for existing sync data (writes nothing)"
    task dry_run: :environment do
      SyncBackfill::BaselineObservationsReport.print(SyncBackfill::BaselineObservations.summary)
    end

    desc "enqueue baseline item snapshot and mapping outbox rows for existing sync data"
    task run: :environment do
      SyncBackfill::BaselineObservationsReport.print(SyncBackfill::BaselineObservations.run!)
    end
  end
end
