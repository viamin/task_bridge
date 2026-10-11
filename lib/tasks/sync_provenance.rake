# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill provenance and baseline outbox rows (DRY_RUN=true previews without writes)"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!(dry_run: ENV["DRY_RUN"] == "true", output: $stdout)
  end
end
