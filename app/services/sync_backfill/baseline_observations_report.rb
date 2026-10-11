# frozen_string_literal: true

module SyncBackfill
  # Human-readable rendering of SyncBackfill::BaselineObservations'
  # summary for the dry-run and run rake tasks (#222 acceptance criteria:
  # "dry-run output summarizing counts by service, confidence, and
  # skipped/incomplete records").
  module BaselineObservationsReport
    module_function

    def print(summary)
      print_items(summary.fetch(:items))
      print_mappings(summary.fetch(:mappings))
    end

    def print_items(items)
      puts "Baseline item snapshots: #{items[:enqueued]} by service #{items[:by_service]}"
      puts "  skipped (#{items[:skipped].length}): #{items[:skipped].map { |row| row[:reason] }.tally}"
    end

    def print_mappings(mappings)
      puts "Baseline mappings: #{mappings[:by_confidence].values.sum} by confidence #{mappings[:by_confidence]}"
      puts "  withheld low-confidence (#{mappings[:withheld].length}): #{mappings[:withheld].map { |row| row[:id] }}"
      puts "  incomplete (#{mappings[:incomplete].length}): #{mappings[:incomplete]}"
    end
  end
end
