# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline item and mapping outbox rows (DRY_RUN=1 reports without writing)"
  task backfill_observations: :environment do
    summary = ENV["DRY_RUN"] == "1" ? SyncBackfill::ObservationBaseline.preview : SyncBackfill::ObservationBaseline.run!
    puts JSON.pretty_generate(summary)
  end
end
