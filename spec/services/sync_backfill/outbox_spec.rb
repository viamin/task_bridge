# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Outbox do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-11T10:00:00Z") }
  let(:item_options) { { service_name: "Backfill", services: [], primary: "PrimaryService", tags: [] } }

  before do
    stub_item_class("BackfillOmniFocusItem", "OmniFocus")
    stub_item_class("BackfillAsanaItem", "Asana")
    stub_item_class("BackfillGithubItem", "Github")
    stub_item_class("BackfillGoogleTasksItem", "GoogleTasks")
  end

  it "seeds idempotent baseline snapshots for representative services" do
    items = [
      BackfillOmniFocusItem, BackfillAsanaItem, BackfillGithubItem, BackfillGoogleTasksItem
    ].each_with_index.map do |klass, index|
      klass.create!(title: "Item #{index}", external_id: "external-#{index}",
                    options: item_options, last_modified: observed_at)
    end

    travel_to(observed_at) do
      described_class.run!(output: StringIO.new)
      described_class.run!(output: StringIO.new)
    end

    rows = OutboxEntry.where(record_kind: "item").order(:external_id)
    expect(rows.size).to eq(4)
    expect(rows.map(&:service_instance)).to contain_exactly(
      "omni_focus:default", "asana:default", "github:default", "google_tasks:default"
    )
    expect(rows.map { |row| row.payload.dig("provenance", "detected_by") }.uniq).to eq(["backfill"])
    expect(rows.map { |row| row.payload.dig("provenance", "baseline") }.uniq).to eq([true])
    expect(rows.map { |row| row.payload["backfilled_at"] }.uniq).to eq([observed_at.iso8601(6)])
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
  end

  it "withholds low-confidence mappings and reports dry-run counts without writes" do
    high_confidence = SyncCollection.create!(title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high")
    low_confidence = SyncCollection.create!(title: "Review", mapping_method: "title_fallback", mapping_confidence: "low")
    BackfillAsanaItem.create!(title: "Confirmed", external_id: "asana-1", sync_collection: high_confidence, options: item_options)
    BackfillGithubItem.create!(title: "Review", external_id: "github-1", sync_collection: low_confidence, options: item_options)

    output = StringIO.new
    described_class.run!(dry_run: true, output:)

    expect(OutboxEntry.count).to eq(0)
    expect(output.string).to include(
      "TaskBridge outbox backfill dry run:",
      "mappings service=asana confidence=high: 1",
      "mappings_withheld_low_confidence service=github confidence=low: 1"
    )
  end

  def stub_item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end)
  end
end
