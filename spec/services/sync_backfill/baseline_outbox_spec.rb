# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::BaselineOutbox do
  let(:item_classes) do
    {
      omnifocus: legacy_item_class("BackfillOmniFocusItem", "Omnifocus"),
      asana: legacy_item_class("BackfillAsanaItem", "Asana"),
      github: legacy_item_class("BackfillGithubItem", "GitHub"),
      google_tasks: legacy_item_class("BackfillGoogleTasksItem", "Google Tasks")
    }
  end

  def legacy_item_class(name, provider_name)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider_name }
      define_method(:external_data) { {} }

      define_singleton_method(:attribute_map) { {} }
    end)
  end

  def create_legacy_item(item_class, service_name, external_id, collection)
    item = item_class.create!(
      title: "Release checklist",
      external_id:,
      sync_collection: collection,
      options: { service_name:, services: [], primary: "Asana", tags: [] }
    )
    item.update_columns(
      source_service_name: nil,
      source_service_instance: nil,
      source_service_type: nil,
      source_external_id: nil,
      source_url: nil,
      source_created_at: nil,
      source_updated_at: nil,
      first_observed_at: nil,
      last_observed_at: nil,
      source_metadata: nil,
      last_snapshot: nil
    )
    item
  end

  it "backfills baseline rows idempotently for OmniFocus, Asana, GitHub, and Google Tasks" do
    collection = SyncCollection.create!(
      title: "Release checklist",
      mapping_method: "source_sync_id",
      mapping_confidence: "high"
    )
    items = [
      create_legacy_item(item_classes[:omnifocus], "OmniFocus", "of-1", collection),
      create_legacy_item(item_classes[:asana], "Asana:work", "asana-1", collection),
      create_legacy_item(item_classes[:github], "GitHub:repo-1", "gh-1", collection),
      create_legacy_item(item_classes[:google_tasks], "Google Tasks:list-1", "gt-1", collection)
    ]

    first_summary = described_class.run!
    described_class.run!

    expect(first_summary[:items]).to include(ready: 4, skipped_incomplete: 0)
    expect(OutboxEntry.where(record_kind: "item")).to have_attributes(count: 4)
    expect(OutboxEntry.where(record_kind: "mapping")).to have_attributes(count: 4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.count).to eq(8)
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)

    omnifocus_row = OutboxEntry.find_by(record_kind: "item", external_id: "of-1")
    expect(omnifocus_row.service_instance).to eq("omnifocus:default")
    expect(omnifocus_row.payload).to include(
      "observed_at" => omnifocus_row.observed_at.utc.iso8601(6),
      "provenance" => { "detected_by" => "backfill", "backfilled_at" => omnifocus_row.observed_at.utc.iso8601(6) }
    )
  end

  it "withholds low-confidence mappings while reporting them" do
    collection = SyncCollection.create!(title: "Uncertain", mapping_method: "manual_backfill", mapping_confidence: "low")
    create_legacy_item(item_classes[:asana], "Asana:work", "asana-low", collection)

    summary = described_class.run!

    expect(summary[:mappings]).to include(ready: 0, skipped_low_confidence: 1)
    expect(OutboxEntry.where(record_kind: "mapping")).to be_empty
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
  end

  it "reports a dry run without mutating provenance or the outbox" do
    collection = SyncCollection.create!(title: "Preview")
    item = create_legacy_item(item_classes[:asana], "Asana:work", "asana-preview", collection)

    summary = described_class.dry_run

    expect(summary[:items]).to include(ready: 1, skipped_incomplete: 0)
    expect(summary[:mappings]).to include(ready: 0, skipped_low_confidence: 1)
    expect(OutboxEntry.count).to eq(0)
    expect(item.reload.source_service_name).to be_nil
  end
end
