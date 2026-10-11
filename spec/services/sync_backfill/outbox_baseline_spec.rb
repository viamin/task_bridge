# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline, :full_options do
  let(:now) { Time.zone.parse("2026-10-11T12:00:00Z") }

  before do
    stub_service_item("BackfillOmnifocusItem", "Omnifocus")
    stub_service_item("BackfillAsanaItem", "Asana")
    stub_service_item("BackfillGithubItem", "Github")
    stub_service_item("BackfillGoogleTasksItem", "GoogleTasks")
  end

  it "creates idempotent baseline snapshots for each supported legacy service" do
    collection = SyncCollection.create!(title: "Release", mapping_method: "source_sync_id", mapping_confidence: "high")
    items = [BackfillOmnifocusItem, BackfillAsanaItem, BackfillGithubItem, BackfillGoogleTasksItem].map do |item_class|
      item = item_class.create!(title: "Release", external_id: item_class.name, sync_collection: collection,
                                last_modified: now - 1.hour)
      item.update_columns(source_service_name: nil, source_service_instance: nil, source_service_type: nil,
                          source_external_id: nil, source_url: nil, source_updated_at: nil,
                          first_observed_at: nil, last_observed_at: nil, last_snapshot: nil)
      item
    end

    first_summary = described_class.run!(now:)
    second_summary = described_class.run!(now: now + 1.hour)

    expect(first_summary).to eq(second_summary)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "item").pluck(:service_type)).to contain_exactly(
      "omnifocus", "asana", "github", "google_tasks"
    )
    expect(OutboxEntry.where(record_kind: "item").pluck(:service_instance)).to all(end_with(":default"))
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)
    expect(OutboxEntry.where(record_kind: "item").first.payload).to include(
      "provenance" => include("detected_by" => "backfill", "backfilled_at" => now.iso8601(6))
    )
  end

  it "reports and withholds low-confidence mappings without writing during a dry run" do
    collection = SyncCollection.create!(title: "Uncertain", mapping_method: "manual_backfill", mapping_confidence: "low")
    item = BackfillAsanaItem.create!(title: "Uncertain", external_id: "asana-1", sync_collection: collection)
    item.update_columns(first_observed_at: nil, last_observed_at: nil)

    summary = described_class.run!(dry_run: true, now:)

    expect(summary).to include(
      mappings_by_confidence: include("low" => 1),
      skipped: include("mapping_low_confidence" => 1)
    )
    expect(OutboxEntry.count).to eq(0)
    expect(item.reload.last_observed_at).to be_nil
  end

  def stub_service_item(name, provider)
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
