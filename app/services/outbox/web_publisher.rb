# frozen_string_literal: true

module Outbox
  # Publishes pending outbox rows to TaskBridge Web in batches
  # (`POST /api/task_bridge/v1/ingestion/batches`, RDR #215, issue #221).
  #
  # Publication is at-least-once and fully decoupled from sync semantics:
  # rows are only marked delivered after TaskBridge Web accepts or replays
  # them, retryable failures back off through OutboxEntry state, and run!
  # never raises — a publication hiccup leaves rows pending for the next
  # sync run or the standalone retry task instead of failing sync.
  class WebPublisher
    SUMMARY_KEYS = { batches: 0, delivered: 0, retryable: 0, failed: 0 }.freeze

    def self.run!(config: Config.resolve, client: nil, now: Time.current)
      new(config:, client:, now:).run!
    end

    def initialize(config:, client:, now: Time.current)
      @config = config
      @client = client || Client.new(config)
      @now = now
      @processed_ids = Set.new
    end

    def run!
      return dry_run if config.dry_run?
      return summary("disabled") unless config.enabled?
      return summary("not_configured") if config.incomplete?

      publish
    end

    private

    attr_reader :config, :now

    def publish
      counts = SUMMARY_KEYS.dup
      loop do
        entries = next_batch
        break if entries.empty?

        counts[:batches] += 1
        outcome = publish_batch(entries)
        counts.merge!(outcome) { |_key, total, batch| total + batch }
        break if outcome[:stopped_reason]
      end
      counts.merge(status: counts.key?(:stopped_reason) ? "incomplete" : "published")
    end

    # Best-effort FIFO by observed_at, honoring each row's retry backoff.
    # Every processed row leaves the due scope (delivered, failed, or
    # scheduled for retry), so the loop always advances; the guard keeps a
    # pathological no-op failure from spinning forever.
    def next_batch
      entries = due_entries.limit(config.batch_size).to_a
      entries.reject! { |entry| @processed_ids.include?(entry.id) }
      @processed_ids.merge(entries.map(&:id))
      entries
    end

    def due_entries
      OutboxEntry.due_for_publication(now).order(:observed_at, :id)
    end

    def publish_batch(entries)
      response = @client.post_batch(Batch.new(entries, now:))
      case response.outcome
      when Response::ROW_RESULTS
        Reconciler.apply(entries:, results: response.row_results, now:)
      when Response::RETRYABLE
        record_batch_failure(entries, response, retryable: true)
      else
        record_batch_failure(entries, response, retryable: false)
      end
    end

    def record_batch_failure(entries, response, retryable:)
      entries.each do |entry|
        entry.record_publication_failure!(
          error_class: response.error_code,
          error_message: response.summary_message,
          retryable:,
          now:
        )
      end
      { delivered: 0, retryable: retryable ? entries.size : 0,
        failed: retryable ? 0 : entries.size, stopped_reason: response.error_code }
    end

    # Renders the exact batches a live run would send — same bodies and
    # batching — without contacting TaskBridge Web and without touching
    # any row's delivery state. Development and backfill preview only
    # (RDR #215): HTTP push stays the sole production ingestion path. The
    # API key never appears here: no request is built, so no headers
    # exist to print.
    def dry_run
      counts = SUMMARY_KEYS.dup.merge(rows: 0)
      loop do
        entries = next_batch
        break if entries.empty?

        batch = Batch.new(entries, now:)
        counts[:batches] += 1
        counts[:rows] += entries.size
        $stdout.puts(JSON.pretty_generate(dry_run_payload(batch, entries)))
      end
      counts.merge(status: "dry_run")
    end

    def dry_run_payload(batch, entries)
      {
        dry_run: true,
        url: "#{config.base_url}#{Batch::ENDPOINT_PATH}",
        row_count: entries.size,
        body: batch.body
      }
    end

    def summary(status)
      SUMMARY_KEYS.dup.merge(status:)
    end
  end
end
