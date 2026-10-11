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

    desc "backfill baseline item snapshots and mapping rows for existing sync data into the outbox (idempotent)"
    task backfill_baseline: :environment do
      summary = SyncBackfill::Baseline.run!
      puts "Baseline backfill: #{summary[:items][:enqueued]} item snapshots enqueued " \
           "(#{summary[:items][:already_backfilled]} already backfilled, #{summary[:items][:incomplete]} incomplete), " \
           "#{summary[:mappings][:enqueued]} mapping rows enqueued " \
           "(#{summary[:mappings][:already_backfilled]} already backfilled, " \
           "#{summary[:mappings][:withheld_low_confidence]} withheld low confidence, " \
           "#{summary[:mappings][:incomplete]} incomplete)"
      puts "Item snapshots by service: #{format_counts(summary[:items_by_service])}"
      puts "Mapping rows by confidence: #{format_counts(summary[:mappings_by_confidence])}"
    end

    desc "summarize what the baseline backfill would enqueue, without writing anything"
    task backfill_baseline_dry_run: :environment do
      summary = SyncBackfill::Baseline.run!(dry_run: true)
      puts "Baseline backfill dry run: would enqueue #{summary[:items][:enqueued]} item snapshots " \
           "(#{summary[:items][:incomplete]} incomplete) and #{summary[:mappings][:enqueued]} mapping rows " \
           "(#{summary[:mappings][:withheld_low_confidence]} would be withheld low confidence, " \
           "#{summary[:mappings][:incomplete]} incomplete); nothing was written"
      puts "Item snapshots by service: #{format_counts(summary[:items_by_service])}"
      puts "Mapping rows by confidence: #{format_counts(summary[:mappings_by_confidence])}"
      summary[:withheld_low_confidence_collections].each do |collection|
        puts "Withheld low confidence: sync_collection #{collection[:sync_collection_id]} " \
             "(#{collection[:members]} members, method: #{collection[:mapping_method]}) #{collection[:title].to_s.inspect}"
      end
    end

    def format_counts(counts)
      return "none" if counts.blank?

      counts.sort_by { |service, _count| [-counts[service], service] }
            .map { |service, count| "#{service}=#{count}" }.join(", ")
    end
  end
end
