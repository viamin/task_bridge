# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline, :full_options do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.parse("2026-10-12T12:00:00Z") }
  let(:output) { StringIO.new }
  let(:item_class) do
    stub_const("BaselineBackfillItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        source_service_type || "Asana"
      end

      def external_data
        {}
      end
    end)
  end

  before { item_class }

  it "creates idempotent baseline snapshots and excludes low-confidence mappings" do
    collection = SyncCollection.create!(
      title: "Release",
      mapping_method: "source_sync_id",
      mapping_confidence: "high"
    )
    low_collection = SyncCollection.create!(
      title: "Maybe release",
      mapping_method: "manual_backfill",
      mapping_confidence: "low"
    )
    create_item("Asana", "asana-1", collection)
    create_item("Omnifocus", "of-1", collection)
    create_item("Github", "gh-1", low_collection)
    create_item("Google Tasks", "gt-1", low_collection)

    first_summary = described_class.run!(now:, output:)
    described_class.run!(now:, output:)

    expect(first_summary[:services]).to include(
      "asana" => 1, "omnifocus" => 1, "github" => 1, "google_tasks" => 1
    )
    expect(first_summary[:mapping_confidence]).to include("high" => 2, "low" => 2)
    expect(first_summary[:skipped]).to include("low_confidence_mappings" => 2)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(2)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to match_array(%w[asana-1 of-1])
    expect(OutboxEntry.find_by(external_id: "of-1", record_kind: "item").service_instance).to eq("omnifocus:default")
    expect(OutboxEntry.find_by(external_id: "asana-1", record_kind: "item").payload.dig("provenance", "detected_by"))
      .to eq("backfill")
  end

  it "reports a preview without mutating provenance or the outbox" do
    item = create_item("Asana", "asana-1")
    item.update_columns(last_observed_at: nil, source_service_name: nil, source_service_instance: nil)

    summary = described_class.run!(dry_run: true, now:, output:)

    expect(summary[:item_snapshots]).to eq(1)
    expect(OutboxEntry.count).to be_zero
    expect(item.reload.last_observed_at).to be_nil
    expect(JSON.parse(output.string)).to include("item_snapshots" => 1)
  end

  def create_item(provider, external_id, collection = nil)
    item_class.new(
      title: external_id,
      external_id:,
      source_service_type: provider,
      sync_collection: collection,
      options: options.merge(service_name: provider)
    ).tap(&:save!)
  end
end
