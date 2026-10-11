# frozen_string_literal: true

# Renders `{name => count}` summaries as "name=count, name=count" lines.
format_counts = lambda do |counts|
  counts.blank? ? "none" : counts.map { |name, count| "#{name}=#{count}" }.join(", ")
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

    desc "backfill baseline outbox rows (item snapshots and mappings) for existing TaskBridge data"
    task backfill: :environment do
      summary = Outbox::Backfill.run!
      items = summary[:items]
      mappings = summary[:mappings]
      puts "Outbox backfill: #{items[:enqueued]} item snapshots enqueued " \
           "(#{items[:already_present]} already present, #{items[:skipped]} skipped), " \
           "#{mappings[:enqueued]} mappings enqueued " \
           "(#{mappings[:already_present]} already present, #{mappings[:withheld]} low-confidence memberships withheld, " \
           "#{mappings[:skipped]} skipped)"
      puts "Items by service: #{format_counts.call(summary[:items_by_service])}"
      puts "Mappings by confidence: #{format_counts.call(summary[:mappings_by_confidence])}"
    end

    desc "summarize what the outbox backfill would enqueue, without writing anything"
    task backfill_dry_run: :environment do
      summary = Outbox::Backfill.preview!
      items = summary[:items]
      mappings = summary[:mappings]
      puts "Outbox backfill dry run (nothing was written): would enqueue #{items[:publishable]} item snapshots " \
           "(#{items[:skipped]} skipped) and #{mappings[:publishable]} mappings " \
           "(#{mappings[:withheld]} low-confidence memberships would be withheld, #{mappings[:skipped]} skipped)"
      puts "Items by service: #{format_counts.call(summary[:items_by_service])}"
      puts "Mappings by confidence: #{format_counts.call(summary[:mappings_by_confidence])}"
      if summary[:provenance_pending]
        warn "Note: source provenance is not fully backfilled yet; apply also runs the " \
             "provenance backfill first, so confidence counts may shift on the real run."
      end
    end
  end
end
