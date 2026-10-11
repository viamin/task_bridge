# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::SourceProvenance do
  let(:item_class) do
    stub_const("BackfillItem", Class.new(Base::SyncItem) do
      def self.attribute_map = {}

      def provider = source_service_type.presence || "Asana"

      def external_data = {}
    end)
  end

  def item_for(provider, external_id:, collection: nil, notes: nil, title: "Existing task")
    item_class.create!(
      options: { service_name: provider, services: [], primary: "Omnifocus", tags: [] },
      external_id:, title:, notes:, sync_collection: collection,
      source_service_type: Base::Service.class_name_for(provider)
    )
  end

  it "creates idempotent baseline snapshots for OmniFocus, Asana, GitHub, and Google Tasks" do
    items = ["Omnifocus", "Asana:work", "Github:repo", "Google Tasks"].map.with_index do |provider, index|
      item_for(provider, external_id: "external-#{index}")
    end

    first_report = described_class.run!
    snapshots = OutboxEntry.where(record_kind: "item").order(:external_id)

    expect(first_report[:items_by_service]).to include(
      "omnifocus" => 1, "asana_work" => 1, "github_repo" => 1, "google_tasks" => 1
    )
    expect(snapshots.size).to eq(4)
    expect(snapshots.map { |row| row.payload.dig("provenance", "detected_by") }).to all(eq("backfill"))
    expect(snapshots.map(&:service_instance)).to contain_exactly(
      "omnifocus:default", "asana:work", "github:repo", "google_tasks:default"
    )
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)

    described_class.run!

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
  end

  it "withholds low-confidence mappings and reports them in a dry run" do
    collection = SyncCollection.create!(title: "Uncertain")
    item_for("Asana", external_id: "asana-1", collection:, title: "One")
    item_for("Omnifocus", external_id: "of-1", collection:, title: "Two")

    report = described_class.run!(dry_run: true)

    expect(report).to include(
      mappings_by_confidence: include("low" => 1),
      skipped: include("low_confidence_mapping" => 2)
    )
    expect(OutboxEntry.exists?).to be(false)
    expect(collection.reload.mapping_method).to be_nil
  end

  it "reports and skips incomplete records without an external ID" do
    item_for("Github", external_id: nil)

    expect(described_class.run!(dry_run: true)[:skipped]).to include("missing_external_id" => 1)
  end
end
