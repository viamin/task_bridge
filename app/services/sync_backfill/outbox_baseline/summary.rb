# frozen_string_literal: true

module SyncBackfill
  class OutboxBaseline
    # Tracks backfill counts by service and mapping confidence so a dry run
    # summarizes exactly what a real run would publish — including the
    # low-confidence memberships withheld from publication, which stay
    # identifiable here for manual cleanup or Web-side review (#222
    # acceptance criteria).
    class Summary
      def self.format(summary)
        items = summary.fetch(:items)
        mappings = summary.fetch(:mappings)
        mode = summary.fetch(:dry_run) ? "dry run" : "complete"
        "Backfill baseline (#{mode}): " \
          "items #{items[:enqueued]} enqueued#{format_bucket(items[:by_service])}, " \
          "#{items[:skipped]} skipped, #{items[:dropped]} dropped; " \
          "mappings #{mappings[:enqueued]} enqueued, " \
          "#{mappings[:withheld]} withheld#{format_bucket(mappings[:by_confidence])}, " \
          "#{mappings[:skipped]} skipped, #{mappings[:dropped]} dropped"
      end

      def self.format_bucket(bucket)
        return if bucket.empty?

        " (#{bucket.sort.map { |key, count| "#{key}: #{count}" }.join(', ')})"
      end

      def initialize(dry_run:)
        @dry_run = dry_run
        @item_counts = { enqueued: 0, skipped: 0, dropped: 0 }
        @mapping_counts = { enqueued: 0, withheld: 0, skipped: 0, dropped: 0 }
        @by_service = Hash.new(0)
        @by_confidence = Hash.new(0)
      end

      def record_item(service_type)
        @item_counts[:enqueued] += 1
        @by_service[service_type] += 1
      end

      def skip_item
        @item_counts[:skipped] += 1
      end

      def drop_item
        @item_counts[:dropped] += 1
      end

      def record_mappings(count, confidence)
        @mapping_counts[:enqueued] += count
        count_mappings(confidence, count)
      end

      def withhold_mappings(count, confidence)
        @mapping_counts[:withheld] += count
        count_mappings(confidence, count)
      end

      def skip_mappings(count)
        @mapping_counts[:skipped] += count
      end

      def drop_mappings(count)
        @mapping_counts[:dropped] += count
      end

      def to_h
        {
          dry_run: @dry_run,
          items: @item_counts.merge(by_service: @by_service.dup),
          mappings: @mapping_counts.merge(by_confidence: @by_confidence.dup)
        }
      end

      private

      def count_mappings(confidence, count)
        @by_confidence[confidence] += count
      end
    end
  end
end
