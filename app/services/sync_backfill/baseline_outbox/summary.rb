# frozen_string_literal: true

module SyncBackfill
  class BaselineOutbox
    # Accumulates the backfill's counts by service and mapping confidence
    # and renders the summary the rake task prints (#222: "counts by
    # service, confidence, and skipped/incomplete records"). Incomplete
    # records are items or memberships that cannot be published because
    # they lack an external_id; withheld memberships are low-confidence
    # (contract `tentative`) or unprovenanced mappings held back from
    # publication per RDR #215's default.
    class Summary
      ITEM_KEYS = %i[total enqueued already_enqueued incomplete].freeze
      MAPPING_KEYS = %i[members enqueued already_enqueued incomplete withheld].freeze
      INCOMPLETE_SAMPLE_SIZE = 10

      def initialize(dry_run: false)
        @dry_run = dry_run
        @item_buckets = {}
        @mapping_buckets = {}
        @incomplete_item_ids = []
      end

      def item_bucket(service_type)
        @item_buckets[service_type] ||= ITEM_KEYS.index_with(0)
      end

      def mapping_bucket(confidence)
        @mapping_buckets[confidence] ||= MAPPING_KEYS.index_with(0)
      end

      def record_incomplete_item(item, bucket)
        bucket[:incomplete] += 1
        @incomplete_item_ids << item.id if @incomplete_item_ids.length < INCOMPLETE_SAMPLE_SIZE
      end

      def to_h
        {
          dry_run: @dry_run,
          items: totals(@item_buckets, ITEM_KEYS),
          items_by_service: sorted(@item_buckets),
          mappings: totals(@mapping_buckets, MAPPING_KEYS),
          mappings_by_confidence: sorted(@mapping_buckets),
          incomplete_item_ids: @incomplete_item_ids.dup
        }
      end

      def render(output = $stdout)
        output.puts "TaskBridge outbox backfill (#{mode})"
        render_items(output)
        render_mappings(output)
        render_incomplete(output)
      end

      private

      def mode
        @dry_run ? "dry run — nothing was written" : "applied"
      end

      def render_items(output)
        output.puts "Item snapshots by service:"
        sorted(@item_buckets).each do |service, counts|
          output.puts "  #{service}: #{counts[:total]} total, #{enqueued(counts)}, " \
                      "#{counts[:already_enqueued]} already in outbox, #{counts[:incomplete]} incomplete (skipped)"
        end
      end

      def render_mappings(output)
        output.puts "Mapping memberships by confidence:"
        sorted(@mapping_buckets).each do |confidence, counts|
          output.puts "  #{confidence}: #{counts[:members]} memberships, #{enqueued(counts)}, " \
                      "#{counts[:already_enqueued]} already in outbox, #{counts[:withheld]} withheld, " \
                      "#{counts[:incomplete]} incomplete (skipped)"
        end
      end

      def render_incomplete(output)
        return if @incomplete_item_ids.empty?

        output.puts "Incomplete items lack an external_id and were skipped; " \
                    "first #{INCOMPLETE_SAMPLE_SIZE} ids: #{@incomplete_item_ids.join(', ')}"
      end

      def enqueued(counts)
        "#{counts[:enqueued]} #{@dry_run ? 'would enqueue' : 'enqueued'}"
      end

      def totals(buckets, keys)
        keys.index_with { |key| buckets.values.sum { |counts| counts[key] } }
      end

      def sorted(buckets)
        buckets.sort.to_h
      end
    end
  end
end
