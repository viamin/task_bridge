# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline, :full_options do
  let(:item_classes) do
    {
      "Omnifocus" => backfill_item_class("BaselineOmnifocusItem", "Omnifocus"),
      "Asana" => backfill_item_class("BaselineAsanaItem", "Asana"),
      "Github" => backfill_item_class("BaselineGithubItem", "Github"),
      "GoogleTasks" => backfill_item_class("BaselineGoogleTasksItem", "GoogleTasks")
    }
  end

  def backfill_item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_singleton_method(:attribute_map) { {} }
      define_method(:provider) { provider }
      define_method(:external_data) { {} }
    end)
  end

  def create_legacy_item(service, number)
    item_classes.fetch(service).create!(
      title: "#{service} task", external_id: "#{service.downcase}-#{number}",
      url: "https://example.test/#{service}/#{number}", last_modified: Time.zone.parse("2026-10-01T12:00:00Z")
    ).tap do |item|
      item.update_columns(
        source_service_name: nil, source_service_instance: nil, source_service_type: nil,
        source_external_id: nil, source_url: nil, source_updated_at: nil,
        first_observed_at: nil, last_observed_at: nil, source_metadata: nil
      )
    end
  end

  it "backfills idempotent baseline snapshots for each supported source" do
    items = item_classes.keys.each_with_index.map { |service, index| create_legacy_item(service, index) }

    first_summary = described_class.run!
    second_summary = described_class.run!

    expect(first_summary[:items]).to eq(4)
    expect(second_summary[:items]).to eq(4)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(items.map { |item| item.reload.source_service_instance }).to all(eq("default"))
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)
    payloads = OutboxEntry.where(record_kind: "item").map(&:payload)
    expect(payloads).to all(include("provenance" => include("detected_by" => "backfill", "baseline" => true)))
  end

  it "publishes confident memberships and reports low-confidence ones without enqueuing them" do
    high_collection = SyncCollection.create!(title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high")
    low_collection = SyncCollection.create!(title: "Review", mapping_method: "manual_backfill", mapping_confidence: "low")
    confirmed = create_legacy_item("Asana", 1)
    withheld = create_legacy_item("Github", 2)
    confirmed.update_column(:sync_collection_id, high_collection.id)
    withheld.update_column(:sync_collection_id, low_collection.id)

    summary = described_class.run!

    expect(summary[:mappings]).to eq(1)
    expect(summary[:mappings_withheld]).to eq(1)
    expect(summary[:confidence]).to include("high" => 1, "low" => 1)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to eq(["asana-1"])
  end

  it "does not write local records in dry-run mode" do
    create_legacy_item("GoogleTasks", 1)

    summary = described_class.run!(dry_run: true)

    expect(summary[:items]).to eq(1)
    expect(OutboxEntry.count).to eq(0)
    expect(Base::SyncItem.last.source_service_name).to be_nil
  end
end
