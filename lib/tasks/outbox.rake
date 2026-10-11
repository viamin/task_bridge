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

    desc "seed baseline outbox rows (item snapshots + mappings) for existing sync data; safe to rerun"
    task backfill_baseline: :environment do
      summary = Outbox::BaselineBackfill.run!
      puts baseline_backfill_summary(summary)
    end

    desc "summarize the baseline outbox backfill without writing anything"
    task backfill_baseline_dry_run: :environment do
      summary = Outbox::BaselineBackfill.run!(dry_run: true)
      puts baseline_backfill_summary(summary)
      warn "Baseline backfill dry run: nothing was written"
    end

    def baseline_backfill_summary(summary)
      [
        "Baseline backfill (dry run: #{summary[:dry_run]})",
        baseline_items_summary(summary[:items]),
        baseline_mappings_summary(summary[:mappings])
      ].join("\n")
    end

    def baseline_items_summary(items)
      ["Items: #{items[:candidates]} candidates — #{items[:enqueued]} enqueued, " \
       "#{items[:already_present]} already present, #{items[:skipped_incomplete]} skipped (incomplete), " \
       "#{items[:write_failures]} write failures"].tap do |lines|
        items[:by_service].each { |service, counts| lines << baseline_group_line(service, counts) }
      end.join("\n")
    end

    def baseline_mappings_summary(mappings)
      ["Mappings: #{mappings[:memberships]} memberships across #{mappings[:collections]} collections — " \
       "#{mappings[:enqueued]} enqueued, #{mappings[:already_present]} already present, " \
       "#{mappings[:withheld]} withheld (low/unknown confidence), " \
       "#{mappings[:skipped_incomplete]} skipped (incomplete), #{mappings[:write_failures]} write failures"]
        .tap do |lines|
          mappings[:by_confidence].each { |confidence, counts| lines << baseline_group_line(confidence, counts) }
        end.join("\n")
    end

    def baseline_group_line(label, counts)
      "  #{label}: #{counts[:enqueued]} enqueued, #{counts[:already_present]} already present, " \
        "#{counts[:withheld]} withheld, #{counts[:skipped_incomplete]} skipped (incomplete)"
    end
  end
end
