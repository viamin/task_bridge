# frozen_string_literal: true

module SyncBackfill
  class Baseline
    # Renders the backfill result for rake output and programmatic use.
    # The dry-run summary is the acceptance surface for #222: counts by
    # service, by mapping confidence and method (so title-derived and
    # ID-derived mappings are visible separately), and every skipped or
    # incomplete record, plus the withheld low-confidence memberships.
    class Summary
      def initialize(dry_run:, provenance:, items:, mappings:)
        @dry_run = dry_run
        @provenance = provenance
        @items = items
        @mappings = mappings
      end

      def to_h
        {
          dry_run: @dry_run,
          provenance: @provenance,
          items: @items,
          mappings: @mappings,
          sync_runs: { enqueued: 0 }
        }
      end

      def render
        [
          "Baseline backfill (#{@dry_run ? 'dry run — nothing was written' : 'completed'})",
          "  provenance upgraded: #{@provenance[:items_backfilled]} sync_items, " \
          "#{@provenance[:collections_backfilled]} sync_collections",
          "  item snapshots: considered #{@items[:considered]}, #{verb} #{@items[:enqueued]}",
          *detail_lines("    by service: ", @items[:by_service]),
          *skipped_lines(@items[:skipped]),
          "  mapping memberships: considered #{@mappings[:considered]}, #{verb} #{@mappings[:enqueued]}",
          *detail_lines("    by confidence: ", @mappings[:by_confidence]),
          *detail_lines("    by method: ", @mappings[:by_method]),
          *detail_lines("    withheld low-confidence: ", @mappings[:withheld]),
          *skipped_lines(@mappings[:skipped]),
          "  sync_run summaries: none (no reliable historical timestamps — RDR #215)"
        ].join("\n")
      end

      private

      def verb
        @dry_run ? "would enqueue" : "enqueued"
      end

      def detail_lines(label, counts)
        return [] if counts.blank?

        ["#{label}#{counts.map { |key, count| "#{key} #{count}" }.join(', ')}"]
      end

      def skipped_lines(skipped)
        return [] if skipped.blank?

        ["    skipped: #{skipped.map { |reason, count| "#{reason} #{count}" }.join(', ')}"]
      end
    end
  end
end
