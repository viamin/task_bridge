# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxSeed do
  let(:observed_at) { Time.zone.parse("2026-10-12T10:00:00Z") }
  let(:options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }
  let(:collection) do
    SyncCollection.create!(
      title: "Release",
      mapping_method: "source_sync_id",
      mapping_confidence: "high",
      mapping_established_at: observed_at
    )
  end

  before do
    create_item("BackfillOmniFocusItem", "Omnifocus", "omnifocus-1", collection:)
    create_item("BackfillAsanaItem", "Asana", "asana-1", collection:, service_name: "Asana:work")
    create_item("BackfillGithubItem", "Github", "github-1", collection:, service_name: "Github:repo")
    create_item("BackfillGoogleTasksItem", "GoogleTasks", "google-tasks-1", collection:)
  end

  it "seeds representative service snapshots and confirmed mappings idempotently" do
    summary = described_class.run!

    expect(summary[:items]).to include(
      "omnifocus" => 1,
      "asana" => 1,
      "github" => 1,
      "google_tasks" => 1
    )
    expect(summary[:mappings]["high"]).to include(
      "omnifocus" => 1,
      "asana" => 1,
      "github" => 1,
      "google_tasks" => 1
    )
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty

    omnifocus_row = OutboxEntry.find_by(record_kind: "item", service_type: "omnifocus")
    expect(omnifocus_row.service_instance).to eq("omnifocus:default")
    expect(omnifocus_row.payload).to include(
      "baseline" => true,
      "provenance" => hash_including("detected_by" => "backfill", "backfilled_at" => observed_at.iso8601(6))
    )
    expect(Base::SyncItem.find_by(external_id: "omnifocus-1").last_snapshot).to be_present

    described_class.run!

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
  end

  it "withholds low-confidence mappings and previews without local writes" do
    low_collection = SyncCollection.create!(
      title: "Ambiguous",
      mapping_method: "title_fallback",
      mapping_confidence: "low",
      mapping_established_at: observed_at
    )
    create_item("BackfillLowOne", "Omnifocus", "low-1", collection: low_collection)
    create_item("BackfillLowTwo", "Github", "low-2", collection: low_collection)

    dry_run_summary = described_class.run!(dry_run: true)

    expect(dry_run_summary[:mappings]["low"]).to include("omnifocus" => 1, "github" => 1)
    expect(dry_run_summary[:skipped]).to include(low_confidence_mapping: 2)
    expect(OutboxEntry.count).to eq(0)
    expect(Base::SyncItem.find_by(external_id: "omnifocus-1").last_snapshot).to be_nil
  end

  def create_item(constant_name, provider, external_id, collection:, service_name: provider)
    item_class = stub_const(constant_name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_method(:external_data) { {} }

      define_singleton_method(:attribute_map) { {} }
    end)
    item_class.create!(
      title: external_id,
      external_id:,
      sync_collection: collection,
      options: options.merge(service_name:)
    ).tap do |item|
      item.update_columns(
        source_service_name: nil,
        source_service_instance: nil,
        source_service_type: nil,
        source_external_id: nil,
        source_url: nil,
        source_created_at: nil,
        source_updated_at: nil,
        first_observed_at: observed_at,
        last_observed_at: observed_at,
        source_metadata: nil,
        last_snapshot: nil
      )
    end
  end
end
