# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    if Thread.current[:global_options]&.fetch(:pretend, false)
      SyncBackfill::Preview.run!
      next
    end

    SyncBackfill::SourceProvenance.run!
    SyncBackfill::Baseline.run!
  end
end
