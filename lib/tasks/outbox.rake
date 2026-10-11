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

    # Baseline backfill (#222): seeds item snapshots and mapping rows for
    # pre-publication sync data so TaskBridge Web starts from known current
    # state. Run DRY_RUN=1 first to preview counts; see
    # docs/backfill-taskbridge-web-baseline.md for the full runbook.
    desc "backfill baseline item snapshots and mapping rows for existing sync data (DRY_RUN=1 previews without writing)"
    task backfill_baseline: :environment do
      dry_run = %w[1 true yes].include?(ENV["DRY_RUN"].to_s.downcase)
      report = SyncBackfill::OutboxBaseline.run!(dry_run:)
      puts SyncBackfill::OutboxBaseline::Summary.render(report)
    end
  end
end
