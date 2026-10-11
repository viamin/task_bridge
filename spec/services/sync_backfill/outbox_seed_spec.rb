# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxSeed, :full_options do
  let(:options) { { service_name: nil, services: [], primary: "Asana", tags: [] } }
  let(:service_definitions) do
    {
      "Omnifocus" => "OmnifocusBackfillItem",
      "Asana" => "AsanaBackfillItem",
      "Github" => "GithubBackfillItem",
      "GoogleTasks" => "GoogleTasksBackfillItem"
    }
  end

  before do
    service_definitions.each do |provider, constant_name|
      stub_const(constant_name, Class.new(Base::SyncItem) do
        define_method(:provider) { provider }
        define_method(:external_data) { {} }

        define_singleton_method(:attribute_map) { {} }
      end)
    end
  end

  it "seeds idempotent baseline snapshots for OmniFocus, Asana, GitHub, and Google Tasks" do
    collection = SyncCollection.create!(title: "Release", mapping_method: "source_sync_id", mapping_confidence: "high")
    records = service_definitions.values.map.with_index do |constant_name, index|
      constant_name.constantize.create!(
        options: options.merge(service_name: index == 1 ? "Asana:work" : nil),
        external_id: "item-#{index}", title: "Release", sync_collection: collection
      )
    end

    first_summary = described_class.run!
    second_summary = described_class.run!

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "item").pluck(:service_instance)).to contain_exactly(
      "omnifocus:default", "asana:work", "github:default", "google_tasks:default"
    )
    expect(OutboxEntry.where(record_kind: "item").map { |entry| entry.payload.dig("provenance", "detected_by") }).to all(eq("backfill"))
    expect(first_summary).to include(items: 4, mappings: 4)
    expect(second_summary).to include(items: 4, mappings: 4)
    expect(records.map { |record| record.reload.source_service_instance })
      .to contain_exactly("default", "work", "default", "default")
  end

  it "reports and withholds low-confidence mappings without writing during preview" do
    collection = SyncCollection.create!(title: "Ambiguous", mapping_method: "manual_backfill", mapping_confidence: "low")
    OmnifocusBackfillItem.create!(options:, external_id: "item-1", title: "Ambiguous", sync_collection: collection)
    incomplete_item = OmnifocusBackfillItem.create!(options:, title: "Incomplete")
    incomplete_item.update_columns(last_observed_at: nil)

    summary = described_class.preview

    expect(summary).to include(items: 1, mappings: 0)
    expect(summary.fetch(:skipped)).to include(incomplete_items: 1, withheld_low_confidence_mappings: 1)
    expect(summary.fetch(:by_confidence)).to include("low" => 1)
    expect(OutboxEntry.count).to eq(0)
    expect(incomplete_item.reload.last_observed_at).to be_nil
  end
end
