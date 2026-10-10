# frozen_string_literal: true

module SyncBackfill
  # Renders the operator summary for SyncBackfill::OutboxBaseline (#222):
  # counts by service and confidence plus skipped/incomplete records, so a
  # dry run can be reviewed before anything is enqueued and withheld
  # low-confidence mappings stay identifiable for manual cleanup.
  class BaselineReport
    def self.render(summary)
      new(summary).render
    end

    def initialize(summary)
      @summary = summary
    end

    def render
      "#{[header, *item_lines, *mapping_lines].join("\n")}\n"
    end

    private

    attr_reader :summary

    def header
      summary[:dry_run] ? "Outbox baseline backfill (dry run — nothing was enqueued)" : "Outbox baseline backfill"
    end

    def item_lines
      items = summary.fetch(:items)
      [
        "Item snapshots#{suffix}: #{headline_count(items, :by_service)} across #{items.fetch(:by_service).size} services",
        *count_lines(items.fetch(:by_service)),
        *skipped_lines(items),
        failure_lines(items)
      ].compact
    end

    def mapping_lines
      mappings = summary.fetch(:mappings)
      [
        "Mapping memberships#{suffix}: #{headline_count(mappings, :by_confidence)}",
        *count_lines(mappings.fetch(:by_confidence)),
        *withheld_lines(mappings),
        *skipped_lines(mappings),
        failure_lines(mappings)
      ].compact
    end

    def suffix
      summary[:dry_run] ? " (would be enqueued)" : ""
    end

    # Dry runs enqueue nothing, so their headline reports the candidates
    # the real run would enqueue; real runs report what actually landed.
    def headline_count(section, candidate_bucket)
      summary[:dry_run] ? section.fetch(candidate_bucket).values.sum : section.fetch(:enqueued)
    end

    def withheld_lines(mappings)
      return if mappings.fetch(:withheld).empty?

      ["Withheld mappings (not published; review locally): #{mappings.fetch(:withheld).values.sum}",
       *count_lines(mappings.fetch(:withheld), indent: "  ")]
    end

    def skipped_lines(section)
      skipped = section.fetch(:skipped)
      return if skipped.empty?

      ["Skipped/incomplete records: #{skipped.values.sum { |scope| scope.values.sum }}",
       *skipped.flat_map { |reason, scopes| ["  #{reason}:", *count_lines(scopes, indent: "    ")] }]
    end

    def failure_lines(section)
      failures = section.fetch(:write_failures)
      "Outbox write failures (re-run re-detects them): #{failures}" if failures.positive?
    end

    def count_lines(counts, indent: "  ")
      counts.map { |label, count| "#{indent}#{label}: #{count}" }
    end
  end
end
