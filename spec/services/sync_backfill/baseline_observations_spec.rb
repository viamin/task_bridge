# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::BaselineObservations do
  describe ".run!" do
    it "delegates to the item snapshot and mapping backfills and merges their summaries" do
      item_summary = { enqueued: 1, skipped_incomplete: 0, by_service: { "omnifocus" => 1 } }
      mapping_summary = { enqueued: 0, withheld_low_confidence: 0, skipped_incomplete: 0, by_confidence: {}, by_service: {} }
      allow(SyncBackfill::ItemSnapshots).to receive(:run!).with(dry_run: true).and_return(item_summary)
      allow(SyncBackfill::MappingObservations).to receive(:run!).with(dry_run: true).and_return(mapping_summary)

      expect(described_class.run!(dry_run: true)).to eq(items: item_summary, mappings: mapping_summary)
    end
  end
end
