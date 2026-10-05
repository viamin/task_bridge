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
    SUMMARY_KEYS = { batches: 0, delivered: 0, retryable: 0, failed: 0, unsupported: 0 }.freeze
    SUPPORTED_PAYLOAD_VERSIONS = [1].freeze

    def self.run!(config: Config.resolve, client: nil, now: Time.current)
      new(config:, client:, now:).run!
    end

    def initialize(config:, client:, now: Time.current)
      @config = config
      @client = client || Client.new(config)
      @now = now
      @cursor = nil
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

        break if publish_entries(entries, counts)
      end
      counts.merge(status: counts.key?(:stopped_reason) ? "incomplete" : "published")
    end

    # Best-effort FIFO by observed_at, honoring each row's retry backoff.
    # Every processed row leaves the due scope (delivered, failed, or
    # scheduled for retry). A forward keyset cursor also advances dry runs,
    # which do not change row state, without growing an IN-list per batch.
    def next_batch
      scope = due_entries
      if @cursor
        scope = scope.where("observed_at > :observed_at OR (observed_at = :observed_at AND id > :id)",
                            observed_at: @cursor.first, id: @cursor.last)
      end
      entries = scope.limit(config.batch_size).to_a
      @cursor = [entries.last.observed_at, entries.last.id] if entries.any?
      entries
    end

    def due_entries
      OutboxEntry.due_for_publication(now).order(:observed_at, :id)
    end

    # A contract requires every row's version to match its enclosing body.
    # Split each selected set into version-specific requests.
    def publish_entries(entries, counts)
      version_batches(entries).each do |version_entries|
        return defer_unsupported_version(version_entries, counts) unless supported_payload_version?(version_entries)
        return true if publish_with_splits(version_entries, counts)
      end
      false
    end

    # RDR #215 forbids sending a newer contract to the fixed v1 endpoint.
    # Keep such rows pending for the compatible endpoint's rollout instead.
    def defer_unsupported_version(entries, counts)
      response = Response.failure("unsupported_payload_version", "payload version #{entries.first.payload_version} has no supported endpoint")
      counts.merge!(record_batch_failure(entries, response, retryable: true)) { |_key, total, batch| total + batch }
      true
    end

    def supported_payload_version?(entries)
      SUPPORTED_PAYLOAD_VERSIONS.include?(entries.first.payload_version)
    end

    # Publishes one homogeneous batch, halving it on a 413 (RDR #215:
    # retryable after smaller batches). Rows are idempotent, so
    # re-attempting the rejected set in halves — down to a single row —
    # lets delivery proceed below the server's limit instead of
    # re-sending the same oversized batch on every run; a single-row 413
    # is an ordinary retryable row failure and stops the run.
    def publish_with_splits(entries, counts)
      counts[:batches] += 1
      response = @client.post_batch(Batch.new(entries, now:))
      return split_entries(entries, counts) if halve_after_413?(entries, response)

      outcome = reconcile_outcome(entries, response)
      counts.merge!(outcome) { |_key, total, batch| total + batch }
      outcome.key?(:stopped_reason)
    end

    def halve_after_413?(entries, response)
      entries.size > 1 && response.outcome == Response::RETRYABLE && response.payload_too_large?
    end

    def split_entries(entries, counts)
      midpoint = (entries.size + 1) / 2
      [entries[0, midpoint], entries[midpoint..]].each do |half|
        return true if publish_with_splits(half, counts)
      end
      false
    end

    def reconcile_outcome(entries, response)
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

        version_batches(entries).each do |version_entries|
          unless supported_payload_version?(version_entries)
            counts[:unsupported] += version_entries.size
            next
          end

          batch = Batch.new(version_entries, now:)
          counts[:batches] += 1
          counts[:rows] += version_entries.size
          # One compact JSON object per line (NDJSON): a multi-batch run
          # stays parseable line-by-line instead of concatenating
          # documents.
          $stdout.puts(JSON.generate(dry_run_payload(batch, version_entries)))
        end
      end
      counts.merge(status: "dry_run")
    end

    def dry_run_payload(batch, entries)
      {
        dry_run: true,
        url: "#{config.base_url.to_s.chomp('/')}#{Batch::ENDPOINT_PATH}",
        row_count: entries.size,
        body: batch.body
      }
    end

    def version_batches(entries)
      entries.group_by(&:payload_version).values
    end

    def summary(status)
      SUMMARY_KEYS.dup.merge(status:)
    end
  end
end
