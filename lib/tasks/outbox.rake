# frozen_string_literal: true

namespace :task_bridge do
  namespace :outbox do
    desc "prune delivered and terminal-failure outbox entries past their retention windows"
    task prune: :environment do
      pruned = Outbox::Prune.run!
      puts "Pruned #{pruned[:delivered]} delivered and #{pruned[:failed]} failed outbox entries"
    end

    desc "publish pending outbox entries to TaskBridge Web (retries rows whose next_retry_at is due)"
    task publish: :environment do
      summary = Outbox::WebPublisher.run!
      reason = " (stopped: #{summary[:stopped_reason]})" if summary[:stopped_reason]
      puts "Outbox publication #{summary[:status]}#{reason}: #{summary[:delivered]} delivered, " \
           "#{summary[:retryable]} awaiting retry, #{summary[:failed]} failed " \
           "across #{summary[:batches]} batches"
    end

    desc "render the pending outbox batches without sending them (development/backfill preview)"
    task publish_dry_run: :environment do
      config = Outbox::WebPublisher::Config.resolve("dry_run" => true)
      summary = Outbox::WebPublisher.run!(config:)
      # Batches go to stdout as one JSON object per line, so the stream
      # stays pipeable (`rake ... | jq .`); this human summary goes to
      # stderr to keep stdout pure NDJSON.
      warn "Outbox dry run: would publish #{summary[:rows]} rows " \
           "across #{summary[:batches]} batches (nothing was sent)"
    end

    desc "backfill baseline item snapshots and mapping rows for existing sync data " \
         "(idempotent; see docs/backfill-taskbridge-web-baseline.md)"
    task backfill_baseline: :environment do
      puts SyncBackfill::OutboxBaseline.render(SyncBackfill::OutboxBaseline.run!)
    end

    desc "preview the baseline backfill summary without writing any outbox rows"
    task backfill_baseline_dry_run: :environment do
      puts SyncBackfill::OutboxBaseline.render(SyncBackfill::OutboxBaseline.run!(dry_run: true))
    end
  end
end
