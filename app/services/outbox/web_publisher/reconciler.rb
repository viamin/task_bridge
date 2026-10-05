# frozen_string_literal: true

module Outbox
  class WebPublisher
    # Applies a 200 OK response's per-row results to the batch's outbox
    # rows (RDR #215 partial-success semantics). Accepted and replayed
    # rows are marked delivered; rejected rows split by their `retryable`
    # flag into backoff-scheduled pending rows or terminal failures for
    # operator review. A row with no corresponding result entry is never
    # assumed delivered: it is recorded as a retryable failure so the
    # at-least-once guarantee cannot silently drop it.
    class Reconciler
      OUTCOME_KEYS = { delivered: 0, retryable: 0, failed: 0 }.freeze
      DELIVERED_STATUSES = %w[accepted replayed].freeze

      def self.apply(entries:, results:, now: Time.current)
        new(entries, results, now).apply
      end

      def initialize(entries, results, now)
        @results_by_key = Array(results).grep(Hash).index_by { |result| result["idempotency_key"] }
        @entries = entries
        @now = now
      end

      def apply
        @entries.each_with_object(OUTCOME_KEYS.dup) do |entry, counts|
          counts[outcome_for(entry)] += 1
        end
      end

      private

      def outcome_for(entry)
        result = @results_by_key[entry.idempotency_key]
        return record_missing_result(entry) if result.nil?
        return deliver(entry) if DELIVERED_STATUSES.include?(result["status"])
        return record_rejection(entry, result) if result["status"] == "rejected"

        record_unknown_result(entry, result)
      end

      def deliver(entry)
        entry.mark_delivered!(at: @now)
        :delivered
      end

      def record_missing_result(entry)
        entry.record_publication_failure!(
          error_class: "missing_result",
          error_message: "no result entry returned for this row",
          retryable: true,
          now: @now
        )
        :retryable
      end

      # Results come from JSON.parse, so `retryable` is a native boolean
      # when present; only an explicit false is terminal. A missing flag
      # stays retryable (at-least-once bias: terminal needs a positive
      # server statement).
      def record_rejection(entry, result)
        retryable = result["retryable"]
        entry.record_publication_failure!(
          error_class: result["error_code"] || "rejected",
          error_message: result["message"],
          retryable: retryable != false,
          now: @now
        )
        retryable == false ? :failed : :retryable
      end

      def record_unknown_result(entry, result)
        entry.record_publication_failure!(
          error_class: "unreconciled_result",
          error_message: "result status #{result['status'].inspect}",
          retryable: true,
          now: @now
        )
        :retryable
      end
    end
  end
end
