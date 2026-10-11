# frozen_string_literal: true

module Outbox
  class Backfill
    # Accumulates backfill counts (by service and mapping confidence) and
    # renders them for the rake tasks' output. Withheld low/unknown
    # confidence memberships are recorded individually so they stay
    # identifiable for later manual cleanup or Web-side review even though
    # the backfill never publishes them.
    class Summary
      ITEM_OUTCOMES = %i[enqueued skipped].freeze
      MAPPING_OUTCOMES = %i[enqueued withheld skipped].freeze

      def initialize(dry_run:)
        @dry_run = dry_run
        @items = { enqueued: 0, skipped: 0, by_service: {} }
        @mappings = { enqueued: 0, withheld: 0, skipped: 0, by_confidence: {} }
        @withheld_members = []
      end

      attr_reader :items, :mappings, :withheld_members

      def dry_run?
        @dry_run
      end

      def count_item(service_type, outcome)
        count(items, :by_service, service_type, outcome)
      end

      def count_mapping(confidence, outcome)
        count(mappings, :by_confidence, confidence, outcome)
      end

      def record_withheld_member(collection:, member:, confidence:)
        withheld_members << {
          sync_collection_id: collection.id,
          title: collection.title,
          item_key: member.item_key,
          confidence:,
          method: collection.mapping_method
        }
      end

      def to_h
        {
          dry_run: dry_run?,
          items:,
          mappings:,
          withheld_members: withheld_members.map(&:dup)
        }
      end

      def render
        [headline, *service_lines, *confidence_lines, *withheld_lines].join("\n")
      end

      private

      def count(totals, grouping, group_key, outcome)
        totals[outcome] += 1
        bucket = totals[grouping][group_key] ||= bucket_for(grouping)
        bucket[outcome] += 1
      end

      def bucket_for(grouping)
        (grouping == :by_service ? ITEM_OUTCOMES : MAPPING_OUTCOMES).index_with { |_outcome| 0 }
      end

      def headline
        suffix = dry_run? ? " (dry run: nothing was written)" : ""
        "Outbox backfill#{suffix}: #{items[:enqueued]} item snapshots enqueued, " \
          "#{mappings[:enqueued]} mapping rows enqueued, " \
          "#{mappings[:withheld]} memberships withheld (low/unknown confidence), " \
          "#{items[:skipped]} items skipped (incomplete)"
      end

      def service_lines
        lines_for(items, :by_service, "item snapshots by service:")
      end

      def confidence_lines
        lines_for(mappings, :by_confidence, "mapping memberships by confidence:")
      end

      def lines_for(totals, grouping, header)
        return [] if totals[grouping].empty?

        [header] + totals[grouping].map do |group_key, bucket|
          outcomes = bucket.map { |outcome, value| "#{value} #{outcome}" }.join(", ")
          "  #{group_key}: #{outcomes}"
        end
      end

      def withheld_lines
        return [] if withheld_members.empty?

        ["withheld memberships held back from publication (review or confirm manually):"] +
          withheld_members.map do |member|
            "  SyncCollection ##{member[:sync_collection_id]} #{member[:title].to_s.inspect} " \
              "member #{member[:item_key]} (confidence: #{member[:confidence]}, " \
              "method: #{member[:method] || 'unknown'})"
          end
      end
    end
  end
end
