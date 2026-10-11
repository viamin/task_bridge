# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::TaskBridgeWeb do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:sync_options) { { service_name: "Google Tasks", services: [], primary: "Asana", tags: [] } }
  let(:item_class) do
    stub_const("TaskBridgeWebBackfillItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Google Tasks"
      end

      def external_data
        {}
      end
    end)
  end

  before { item_class }

  it "enqueues idempotent baseline snapshots and only publishable mappings" do
    collection = SyncCollection.create!(
      title: "Release",
      mapping_method: "title_fallback",
      mapping_confidence: "medium",
      mapping_last_observed_at: observed_at
    )
    item_class.create!(
      title: "Release",
      external_id: "google-1",
      sync_collection: collection,
      options: sync_options,
      first_observed_at: observed_at,
      last_observed_at: observed_at
    )

    described_class.run!(output: StringIO.new)
    described_class.run!(output: StringIO.new)

    item_row = OutboxEntry.find_by(record_kind: "item")
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(1)
    expect(item_row).to have_attributes(service_type: "google_tasks", service_instance: "google_tasks:default")
    expect(item_row.payload).to include(
      "observed_at" => "2026-10-11T12:00:00.000000Z",
      "provenance" => include("detected_by" => "backfill", "backfilled_at" => "2026-10-11T12:00:00.000000Z")
    )
    expect(OutboxEntry.find_by(record_kind: "mapping").payload["mapping_confidence"]).to eq("inferred")
  end

  it "reports but withholds low-confidence memberships without writing in dry-run mode" do
    collection = SyncCollection.create!(title: "Uncertain", mapping_method: "manual_backfill", mapping_confidence: "low")
    item_class.create!(
      title: "Uncertain",
      external_id: "google-2",
      sync_collection: collection,
      options: sync_options
    )
    output = StringIO.new

    described_class.run!(dry_run: true, output:)

    expect(OutboxEntry.all).to be_empty
    expect(output.string).to include(
      "items by service: google_tasks=1",
      "mappings by confidence: low=1",
      "low-confidence mappings withheld: 1"
    )
  end

  it "summarizes incomplete source records" do
    item_class.create!(title: "No provider id", options: sync_options)
    output = StringIO.new

    described_class.run!(dry_run: true, output:)

    expect(output.string).to include("skipped/incomplete: missing_external_id=1")
  end
end
