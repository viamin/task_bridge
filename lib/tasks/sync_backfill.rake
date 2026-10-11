# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill baseline item snapshots and confirmed/inferred mapping memberships (DRY_RUN=true previews only)"
  task backfill_observations: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("DRY_RUN", false))
    summary = SyncBackfill::Observations.run!(dry_run:)
    mode = dry_run ? "Dry run" : "Backfill"
    puts "#{mode}: #{summary.to_json}"
  end
end
