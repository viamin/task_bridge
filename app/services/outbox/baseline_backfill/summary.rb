# frozen_string_literal: true

module Outbox
  class BaselineBackfill
    # Accumulates backfill counts and renders the operator-facing summary
    # (#222): counts by service, counts by mapping confidence (including
    # withheld low-confidence memberships), and skipped/incomplete records
    # with reasons. A dry run reports the same shape with "to enqueue"
    # wording because nothing was written.
    class Summary
      UNKNOWN = "unknown"

      def initialize(dry_run: false)
        @dry_run = dry_run
        @item_totals = { total: 0, enqueued: 0, already_backfilled: 0, skipped: 0 }
        @items_by_service = {}
        @mapping_totals = { memberships: 0, enqueued: 0, already_backfilled: 0, withheld: 0, skipped: 0 }
        @mappings_by_confidence = {}
        @skip_reasons = Hash.new(0)
      end

      # `outcome` is a symbol (:enqueued, :already_backfilled, :skipped,
      # :withheld) or a [:skipped, reason] pair for skipped records.
      def record_item(service, outcome)
        @item_totals[:total] += 1
        outcome, reason = normalize(outcome)
        @skip_reasons[reason] += 1 if reason
        apply(@item_totals, outcome)
        apply(item_bucket(service), outcome)
      end

      # Skipped rows are counted per potential outbox row, so one broken
      # sync item can account for both an item skip and a mapping skip.
      def record_mapping(confidence, outcome)
        @mapping_totals[:memberships] += 1
        outcome, reason = normalize(outcome)
        @skip_reasons[reason] += 1 if reason
        apply(@mapping_totals, outcome)
        apply(mapping_bucket(confidence), outcome)
      end

      def to_h
        {
          dry_run: @dry_run,
          items: @item_totals.dup.merge(by_service: @items_by_service.deep_dup),
          mappings: @mapping_totals.dup.merge(by_confidence: @mappings_by_confidence.deep_dup),
          skip_reasons: @skip_reasons.dup
        }
      end

      def render
        [
          header,
          items_line,
          *service_lines,
          mappings_line,
          *confidence_lines,
          *skip_reason_lines
        ].join("\n")
      end

      private

      def normalize(outcome)
        outcome.is_a?(Array) ? outcome : [outcome, nil]
      end

      def apply(bucket, outcome)
        bucket[outcome] += 1 if bucket.key?(outcome)
      end

      def item_bucket(service)
        @items_by_service[service] ||= { enqueued: 0, already_backfilled: 0, skipped: 0 }
      end

      def mapping_bucket(confidence)
        @mappings_by_confidence[confidence] ||= { enqueued: 0, already_backfilled: 0, withheld: 0, skipped: 0 }
      end

      def header
        @dry_run ? "Baseline backfill dry run (nothing was enqueued)" : "Baseline backfill"
      end

      def items_line
        "Items: #{@item_totals[:total]} total, #{@item_totals[:enqueued]} #{enqueue_word}, " \
          "#{@item_totals[:already_backfilled]} already backfilled, #{@item_totals[:skipped]} skipped"
      end

      def mappings_line
        "Mappings: #{@mapping_totals[:memberships]} memberships, #{@mapping_totals[:enqueued]} #{enqueue_word}, " \
          "#{@mapping_totals[:already_backfilled]} already backfilled, #{@mapping_totals[:withheld]} withheld, " \
          "#{@mapping_totals[:skipped]} skipped"
      end

      def service_lines
        @items_by_service.sort.map do |service, counts|
          "  #{service}: #{counts_sentence(counts)}"
        end
      end

      def confidence_lines
        @mappings_by_confidence.sort.map do |confidence, counts|
          "  #{confidence} confidence: #{counts_sentence(counts)}"
        end
      end

      def skip_reason_lines
        return [] if @skip_reasons.empty?

        reasons = @skip_reasons.sort.map { |reason, count| "#{count} #{reason}" }.join(", ")
        ["  skipped reasons: #{reasons}"]
      end

      def counts_sentence(counts)
        parts = []
        parts << "#{counts[:enqueued]} #{enqueue_word}" if counts[:enqueued].positive?
        parts << "#{counts[:already_backfilled]} already backfilled" if counts[:already_backfilled].positive?
        parts << "#{counts[:withheld]} withheld" if counts[:withheld].to_i.positive?
        parts << "#{counts[:skipped]} skipped" if counts[:skipped].positive?
        parts.empty? ? "none" : parts.join(", ")
      end

      def enqueue_word
        @dry_run ? "to enqueue" : "enqueued"
      end
    end
  end
end
