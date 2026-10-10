# frozen_string_literal: true

# Renders SyncBackfill::OutboxBaseline summaries as human-readable lines
# for the backfill rake tasks (#222). Kept here (not in the service) so
# the service stays a pure data operation.
module OutboxBaselineReport
  module_function

  def puts_summary(summary)
    mode = summary.fetch(:dry_run) ? "would enqueue" : "enqueued"
    items = summary.fetch(:items)
    puts "Baseline items: #{items.fetch(:total)} total, #{items.fetch(:enqueued)} #{mode}, " \
         "#{items.fetch(:skipped)} skipped (incomplete records)"
    items.fetch(:by_service).each do |service, counts|
      puts "  #{service}: #{counts[:enqueued]} #{mode}, #{counts[:skipped]} skipped"
    end

    mappings = summary.fetch(:mappings)
    puts "Baseline mappings: #{mappings.fetch(:total)} memberships, #{mappings.fetch(:enqueued)} #{mode}, " \
         "#{mappings.fetch(:withheld)} withheld (low confidence), #{mappings.fetch(:skipped)} skipped"
    mappings.fetch(:by_confidence).each do |confidence, count|
      puts "  confidence #{confidence}: #{count}"
    end
    mappings.fetch(:by_service).each do |service, counts|
      puts "  #{service}: #{counts[:enqueued]} #{mode}, #{counts[:withheld]} withheld, #{counts[:skipped]} skipped"
    end
    return if summary.fetch(:dry_run)

    puts "Rerunning the backfill is safe: existing rows are re-found, not duplicated"
  end

  # Low-confidence memberships are only listed in the dry-run summary
  # (#222): publication withholds them, so the wet run reports counts.
  def puts_withheld(summary)
    withheld = summary.fetch(:mappings).fetch(:withheld_memberships)
    return if withheld.empty?

    puts "Withheld low-confidence memberships (review or let a later sync upgrade them):"
    withheld.each do |membership|
      puts "  sync_collection #{membership[:sync_collection_id]} " \
           "(#{membership[:title]}): #{membership[:item_key]} " \
           "[#{membership[:mapping_method]}/#{membership[:confidence]}]"
    end
  end
end

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

    desc "seed the outbox with baseline item snapshots and mapping rows for existing sync data (#222)"
    task backfill_baseline: :environment do
      summary = SyncBackfill::OutboxBaseline.run!
      OutboxBaselineReport.puts_summary(summary)
    end

    desc "summarize what the baseline backfill would enqueue, writing nothing (#222)"
    task backfill_baseline_dry_run: :environment do
      summary = SyncBackfill::OutboxBaseline.run!(dry_run: true)
      OutboxBaselineReport.puts_summary(summary)
      OutboxBaselineReport.puts_withheld(summary)
      puts "Dry run: no rows were written and no provenance was backfilled"
    end
  end
end
