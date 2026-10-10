# frozen_string_literal: true

module Outbox
  class Backfill
    # Accumulates the backfill's counts (#222) and renders them for the
    # rake task output. Counter hashes default to zero so every bucket is
    # always addressable.
    class Summary
      ITEM_COUNTS = %i[enqueued existing skipped_incomplete].freeze
      MAPPING_COUNTS = %i[memberships enqueued existing skipped_incomplete].freeze

      def initialize(dry_run: false)
        @dry_run = dry_run
        @items = ITEM_COUNTS.index_with { 0 }
        @mappings = MAPPING_COUNTS.index_with { 0 }
        @items_by_service = Hash.new(0)
        @mappings_by_confidence = Hash.new(0)
      end

      def count_item_service(service_instance)
        items_by_service[service_instance] += 1
      end

      def count_item(bucket)
        items[bucket] += 1
      end

      def count_membership_confidence(confidence, count = 1)
        mappings_by_confidence[confidence] += count
      end

      def count_memberships(count)
        mappings[:memberships] += count
      end

      def count_mapping(bucket, count = 1)
        mappings[bucket] += count
      end

      def to_h
        {
          items: items.merge(by_service: items_by_service),
          mappings: mappings.merge(
            withheld_low_confidence: withheld_low_confidence,
            skipped_unknown_confidence: mappings_by_confidence.fetch(Backfill::UNKNOWN_CONFIDENCE, 0),
            by_confidence: mappings_by_confidence
          )
        }
      end

      def format
        [
          "Outbox backfill #{mode_label}:",
          "  items: #{items[:enqueued]} enqueued (#{items[:existing]} already present), " \
          "#{items[:skipped_incomplete]} skipped incomplete; " \
          "by service: #{format_counts(items_by_service)}",
          "  mappings: #{mappings[:enqueued]} enqueued (#{mappings[:existing]} already present), " \
          "#{withheld_low_confidence} withheld low confidence, " \
          "#{mappings[:skipped_incomplete]} skipped incomplete, " \
          "#{to_h[:mappings][:skipped_unknown_confidence]} skipped unknown confidence; " \
          "by confidence: #{format_counts(mappings_by_confidence)}"
        ].join("\n")
      end

      private

      attr_reader :dry_run, :items, :mappings, :items_by_service, :mappings_by_confidence

      # Withheld rows never reach the outbox (#222 policy), so their count
      # is derived from the confidence tallies rather than tracked inline.
      def withheld_low_confidence
        mappings_by_confidence.fetch(Backfill::WITHHELD_CONFIDENCE, 0)
      end

      def mode_label
        dry_run ? "dry run (nothing was enqueued)" : "complete"
      end

      def format_counts(counts)
        return "none" if counts.empty?

        counts.sort.map { |bucket, count| "#{bucket}=#{count}" }.join(", ")
      end
    end
  end
end
