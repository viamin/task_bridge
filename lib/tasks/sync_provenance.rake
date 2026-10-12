# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill provenance, baseline item snapshots, and confirmed mappings (DRY_RUN=1 previews only)"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!(dry_run: ENV.fetch("DRY_RUN", "0") == "1")
  end
end
