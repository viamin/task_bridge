# frozen_string_literal: true

module SyncBackfill
  class OutboxBaseline
    # Dry-run/real-run accounting for OutboxBaseline: counts by service for
    # item snapshots, and counts by mapping confidence (including the
    # withheld low-confidence bucket) for mapping rows, so operators can
    # review what the backfill did (or would do) before enabling
    # publication to TaskBridge Web.
    class Summary
      def initialize
        @items_by_service = Hash.new(0)
        @items_skipped = 0
        @mappings_by_confidence = Hash.new(0)
        @mappings_withheld = 0
        @mappings_skipped = 0
      end

      def record_item(service_type)
        @items_by_service[service_type] += 1
      end

      def record_item_skipped
        @items_skipped += 1
      end

      def record_mapping(confidence, count: 1)
        @mappings_by_confidence[confidence] += count
      end

      def record_mapping_withheld(count: 1)
        @mappings_withheld += count
      end

      def record_mapping_skipped(count: 1)
        @mappings_skipped += count
      end

      def to_h
        {
          items: { by_service: @items_by_service.dup, skipped: @items_skipped },
          mappings: {
            by_confidence: @mappings_by_confidence.dup,
            withheld_low_confidence: @mappings_withheld,
            skipped: @mappings_skipped
          }
        }
      end
    end
  end
end
