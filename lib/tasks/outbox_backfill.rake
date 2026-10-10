# frozen_string_literal: true

# Renders the SyncBackfill::BaselineOutbox summary hash (#222) as the
# human-readable dry-run/real-run report the issue requires: counts by
# service, by confidence, and skipped/incomplete records.
module BaselineBackfillReport
  module_function

  def render(summary)
    items = summary[:items]
    mappings = summary[:mappings]
    lines = [
      summary[:dry_run] ? "Baseline outbox backfill (dry run: nothing was written)" : "Baseline outbox backfill",
      "Items: #{items[:enqueued]} enqueued, #{items[:existing]} already present, " \
      "#{items[:skipped]} skipped (no external id), #{items[:errors]} errors",
      "  items by service: #{format_counts(items[:by_service])}",
      "Mappings: #{mappings[:enqueued]} enqueued, #{mappings[:existing]} already present, " \
      "#{mappings[:withheld]} withheld (low confidence), " \
      "#{mappings[:skipped_members]} skipped members, #{mappings[:errors]} errors",
      "  mappings by confidence: #{format_counts(mappings[:by_confidence])}",
      "  withheld by confidence: #{format_counts(mappings[:withheld_by_confidence])}"
    ]
    lines.join("\n")
  end

  def format_counts(counts)
    return "none" if counts.empty?

    counts.sort_by { |key, _count| key.to_s }.map { |key, count| "#{key}=#{count}" }.join(", ")
  end
end

namespace :task_bridge do
  namespace :outbox do
    desc "backfill baseline item snapshots and mapping rows into the outbox for existing sync data"
    task backfill_baseline: :environment do
      puts BaselineBackfillReport.render(SyncBackfill::BaselineOutbox.run!)
    end

    desc "summarize what the baseline outbox backfill would enqueue, without writing anything"
    task backfill_baseline_dry_run: :environment do
      puts BaselineBackfillReport.render(SyncBackfill::BaselineOutbox.dry_run!)
    end
  end
end
