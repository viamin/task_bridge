# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill baseline item snapshots, provenance, and mapping metadata (DRY_RUN=1 previews only)"
  task backfill_sync_provenance: :environment do
    dry_run = ENV.fetch("DRY_RUN", "false").casecmp?("true") || ENV["DRY_RUN"] == "1"
    puts JSON.pretty_generate(SyncBackfill::SourceProvenance.run!(dry_run:))
  end
end
