# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill source provenance, baseline item snapshots, and confirmed mappings (DRY_RUN=1 previews)"
  task backfill_sync_provenance: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", false))
    puts JSON.generate(SyncBackfill::SourceProvenance.run!(dry_run:))
  end
end
