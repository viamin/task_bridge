# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill outbox baseline item snapshots and sync collection mappings " \
       "for TaskBridge Web (runs backfill_sync_provenance first; idempotent)"
  task backfill_outbox_baseline: :environment do
    # Source identity and mapping confidence feed the outbox identities and
    # the low-confidence withholding decision, so populate them before
    # seeding baseline rows (both backfills are idempotent reruns).
    Rake::Task["task_bridge:backfill_sync_provenance"].invoke
    summary = SyncBackfill::OutboxBaseline.run!
    puts format_outbox_baseline_summary(summary)
  end

  desc "summarize the outbox baseline backfill without enqueueing anything " \
       "(run task_bridge:backfill_sync_provenance first for final counts)"
  task backfill_outbox_baseline_dry_run: :environment do
    summary = SyncBackfill::OutboxBaseline.preview
    puts format_outbox_baseline_summary(summary)
    warn "Dry run only: nothing was enqueued and no tables were written"
  end

  def format_outbox_baseline_summary(summary)
    items = summary[:items]
    mappings = summary[:mappings]
    <<~SUMMARY
      Outbox baseline backfill#{' (dry run)' if summary[:dry_run]}:
        Items: #{items[:planned]} snapshots planned (#{items[:created]} created, #{items[:already_present]} already present), #{items[:skipped]} skipped (incomplete records)
        Item snapshots by service: #{format_counts(items[:by_service])}
        Mappings: #{mappings[:planned]} memberships planned (#{mappings[:created]} created, #{mappings[:already_present]} already present), #{mappings[:withheld]} withheld (low confidence), #{mappings[:skipped]} skipped (incomplete records)
        Mappings by confidence: #{format_counts(mappings[:by_confidence])}
        Mappings by service: #{format_counts(mappings[:by_service])}
    SUMMARY
  end

  def format_counts(counts)
    return "none" if counts.blank?

    counts.sort_by { |service, _| service }.map { |service, count| "#{service}=#{count}" }.join(", ")
  end
end
