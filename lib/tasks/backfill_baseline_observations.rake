# frozen_string_literal: true

namespace :task_bridge do
  desc "backfill baseline snapshot/mapping observations for existing sync data (DRY_RUN=1 to preview counts only)"
  task backfill_baseline_observations: :environment do
    dry_run = %w[1 true yes].include?(ENV["DRY_RUN"].to_s.downcase)
    summary = SyncBackfill::BaselineObservations.run!(dry_run:)

    puts dry_run ? "Baseline observation backfill (DRY RUN — nothing was written):" : "Baseline observation backfill complete:"
    items = summary.fetch(:items)
    puts "  items: #{items['baseline']} baseline, #{items['skipped_incomplete']} skipped incomplete, #{items['already_observed']} already observed"
    puts "  items by service: #{items['by_service'].map { |service, count| "#{service}=#{count}" }.join(', ')}"
    mappings = summary.fetch(:mappings)
    withheld = mappings["withheld_collections_by_confidence"].map { |confidence, count| "#{confidence}=#{count}" }.join(", ")
    puts "  mappings: #{mappings['published_members']} members published, " \
         "#{mappings['withheld_members']} members withheld (collections by confidence: #{withheld.presence || 'none'}), " \
         "#{mappings['skipped_incomplete_members']} members skipped incomplete"
  end
end
