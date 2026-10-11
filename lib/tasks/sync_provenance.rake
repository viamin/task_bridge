# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill provenance and baseline TaskBridge Web outbox rows (DRY_RUN=1 previews only)"
  task backfill_sync_provenance: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", false))
    SyncBackfill::SourceProvenance.run!(dry_run:, output: $stdout)
  end
end
