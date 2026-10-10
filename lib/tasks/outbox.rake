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

    desc "backfill baseline item snapshots and mapping rows into the outbox for existing sync data (#222)"
    task backfill_baseline: :environment do
      puts backfill_summary_text(Outbox::Backfill.run!)
    end

    desc "preview the baseline backfill counts without writing any outbox rows (#222)"
    task backfill_baseline_dry_run: :environment do
      puts backfill_summary_text(Outbox::Backfill.run!(dry_run: true))
    end
  end
end

# Rendering helper shared by the backfill tasks; defined at the rake file's
# top level so both tasks (and their specs) see the same output shape.
def backfill_summary_text(summary)
  lines = ["Outbox baseline backfill #{summary[:status]}:"]
  lines << "  items: #{counts(summary[:items])}"
  summary[:items][:by_service].each do |service, service_counts|
    lines << "    item #{service}: #{counts(service_counts)}"
  end
  lines << "  mappings: #{counts(summary[:mappings])}"
  summary[:mappings][:by_service].each do |service, service_counts|
    lines << "    mapping #{service}: #{counts(service_counts)}"
  end
  lines << "  mapping confidence: #{tally(summary[:mappings][:by_confidence])}"
  lines << "  skipped reasons: #{tally(summary[:skipped_reasons])}"
  lines.join("\n")
end

def counts(counts)
  counts.reject { |_outcome, count| count.is_a?(Hash) }
        .map { |outcome, count| "#{outcome}=#{count}" }.join(" ")
end

def tally(counts)
  return "none" if counts.empty?

  counts.map { |value, count| "#{value}=#{count}" }.join(" ")
end
