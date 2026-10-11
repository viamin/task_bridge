# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill explicit sync item provenance and sync collection mapping metadata"
  task backfill_sync_provenance: :environment do
    SyncBackfill::SourceProvenance.run!
  end

  desc "seed baseline item and mapping outbox rows for existing sync data " \
       "(run backfill_sync_provenance first; see docs/backfilling-taskbridge-web.md)"
  task backfill_outbox_baseline: :environment do
    summary = SyncBackfill::OutboxBaseline.run!
    puts JSON.pretty_generate(summary)
  end

  desc "preview the baseline outbox rows backfill_outbox_baseline would create, without writing them"
  task backfill_outbox_baseline_dry_run: :environment do
    summary = SyncBackfill::OutboxBaseline.run!(dry_run: true)
    puts JSON.pretty_generate(summary)
  end
end
