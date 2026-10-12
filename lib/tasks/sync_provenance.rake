# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill source provenance and baseline TaskBridge Web outbox records"
  task backfill_sync_provenance: :environment do
    puts SyncBackfill::SourceProvenance.run!.to_json
  end

  desc "preview source provenance and baseline outbox backfill without writing"
  task backfill_sync_provenance_dry_run: :environment do
    puts SyncBackfill::SourceProvenance.run!(dry_run: true).to_json
  end
end
