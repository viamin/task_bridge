# frozen_string_literal: true

namespace :task_bridge do
  namespace :outbox do
    desc "backfill baseline item snapshots and confirmed/inferred mappings (DRY_RUN=1 previews only)"
    task backfill: :environment do
      dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", false))
      summary = SyncBackfill::OutboxBaseline.run!(dry_run:)
      puts "Outbox backfill#{' dry run' if dry_run}: #{summary.inspect}"
    end
  end
end
