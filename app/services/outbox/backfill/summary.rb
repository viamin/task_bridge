# frozen_string_literal: true

module Outbox
  class Backfill
    # Tallies what the backfill enqueued, deduped, withheld, and skipped,
    # and renders it as the operator-facing summary (the dry-run task
    # prints exactly this). Counts are keyed per dimension the runbook
    # needs: item snapshots and skips by service, mapping rows by
    # confidence, and withheld low-confidence memberships by raw local
    # confidence so they stay identifiable for local review.
    class Summary
      ITEM_BUCKETS = %i[enqueued already_enqueued skipped].freeze
      MAPPING_BUCKETS = %i[enqueued already_enqueued withheld skipped].freeze

      ITEM_LABELS = {
        enqueued: "enqueued by service",
        already_enqueued: "already enqueued (deduped) by service",
        skipped: "skipped (service/reason)"
      }.freeze
      MAPPING_LABELS = {
        enqueued: "enqueued by confidence",
        already_enqueued: "already enqueued (deduped) by confidence",
        withheld: "withheld by confidence (not published; review locally)",
        skipped: "skipped (reason)"
      }.freeze
      LABELS = { items: ITEM_LABELS, mappings: MAPPING_LABELS }.freeze

      def self.render(summary)
        header = summary[:dry_run] ? "Outbox backfill dry run (no outbox rows are written)" : "Outbox backfill"
        [header, *render_section(:items, "item snapshots", summary[:items]),
         *render_section(:mappings, "mapping rows", summary[:mappings])].join("\n")
      end

      def self.render_section(section, title, counts_by_bucket)
        ["  #{title}:"].concat(
          counts_by_bucket.map do |bucket, counts|
            label = LABELS.fetch(section).fetch(bucket)
            values = counts.empty? ? "none" : counts.map { |key, count| "#{key}=#{count}" }.join(", ")
            "    #{label}: #{values}"
          end
        )
      end

      def initialize(dry_run:)
        @dry_run = dry_run
        @items = Tally.new(ITEM_BUCKETS)
        @mappings = Tally.new(MAPPING_BUCKETS)
      end

      attr_reader :items, :mappings

      def to_h
        {
          dry_run: @dry_run,
          items: items.counts,
          mappings: mappings.counts
        }
      end

      # One bucket-keyed set of sorted count hashes.
      class Tally
        def initialize(buckets)
          @tallies = buckets.index_with { Hash.new(0) }
        end

        def count(bucket, key, amount = 1)
          @tallies.fetch(bucket)[key] += amount
        end

        def counts
          @tallies.transform_values { |bucket| bucket.sort.to_h }
        end
      end
    end
  end
end
