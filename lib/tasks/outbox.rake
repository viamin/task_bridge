# frozen_string_literal: true

namespace :task_bridge do
  namespace :outbox do
    desc "seed the outbox with baseline item snapshots and collection mappings for existing sync data (#222; idempotent)"
    task backfill_baseline: :environment do
      SyncBackfill::OutboxBaseline.run!
    end

    desc "preview the baseline outbox backfill counts by service and confidence without enqueuing anything"
    task backfill_baseline_dry_run: :environment do
      SyncBackfill::OutboxBaseline.run!(dry_run: true)
    end

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
  end
end
