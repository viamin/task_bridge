# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:item_classes) do
    {
      "Omnifocus" => stub_item_class("BaselineOmnifocusItem", "Omnifocus"),
      "Asana" => stub_item_class("BaselineAsanaItem", "Asana"),
      "Github" => stub_item_class("BaselineGithubItem", "Github"),
      "GoogleTasks" => stub_item_class("BaselineGoogleTasksItem", "GoogleTasks")
    }
  end

  def stub_item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_method(:external_data) { {} }

      define_singleton_method(:attribute_map) { {} }
    end)
  end

  def create_item(item_class, service_name, collection, external_id)
    item_class.create!(
      title: "Release checklist",
      external_id:,
      sync_collection: collection,
      options: { service_name:, services: [], primary: "Omnifocus", tags: [] }
    )
  end

  it "seeds idempotent baseline snapshots and mappings for existing service records" do
    collection = SyncCollection.create!(title: "Release checklist", mapping_method: "source_sync_id", mapping_confidence: "high")
    items = item_classes.map do |service_name, item_class|
      create_item(item_class, service_name, collection, service_name.downcase)
    end

    travel_to(observed_at) do
      first = described_class.run!
      second = described_class.run!

      expect(first).to include(items: 4, mappings: 4, dry_run: false)
      expect(second).to include(items: 4, mappings: 4, dry_run: false)
    end

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)
    expect(OutboxEntry.find_by(external_id: "omnifocus").service_instance).to eq("omnifocus:default")
    expect(OutboxEntry.find_by(external_id: "googletasks").payload["provenance"]).to include(
      "detected_by" => "backfill", "baseline" => true, "backfilled_at" => observed_at.iso8601(6)
    )
  end

  it "reports low-confidence and incomplete records without writing during a dry run" do
    collection = SyncCollection.create!(title: "Uncertain", mapping_method: "manual_backfill", mapping_confidence: "low")
    item = create_item(item_classes.fetch("Asana"), "Asana:work", collection, "asana-1")
    item.update_columns(source_service_name: nil, source_service_type: nil, source_external_id: nil, last_observed_at: nil)
    item_classes.fetch("Github").create!(title: "Incomplete", options: { services: [], primary: "Omnifocus", tags: [] })

    summary = described_class.run!(dry_run: true, now: observed_at)

    expect(summary).to include(
      items: 1,
      items_skipped_incomplete: 1,
      mappings_withheld_low_confidence: 1,
      dry_run: true,
      services: { "asana" => 1 },
      confidences: { "low" => 1 }
    )
    expect(item.reload.last_observed_at).to be_nil
    expect(OutboxEntry.count).to eq(0)
  end
end
