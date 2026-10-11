# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill provenance, baseline item snapshots, and mapping rows (DRY_RUN=1 previews only)"
  task backfill_sync_provenance: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", false))
    report = SyncBackfill::SourceProvenance.run!(dry_run:)
    puts JSON.generate(report.merge(dry_run:))
  end
end
