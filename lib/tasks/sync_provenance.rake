# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill provenance, baseline snapshots, and confident mapping memberships (DRY_RUN=1 previews only)"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!(dry_run: ENV["DRY_RUN"] == "1")
  end
end
