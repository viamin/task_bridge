# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::BaselineOutbox, :full_options do
  let(:backfilled_at) { Time.zone.parse("2026-10-12T12:00:00Z") }
  let(:item_classes) do
    {
      asana: stub_item_class("BackfillAsanaItem", "Asana"),
      omnifocus: stub_item_class("BackfillOmniFocusItem", "OmniFocus"),
      github: stub_item_class("BackfillGithubItem", "Github"),
      google_tasks: stub_item_class("BackfillGoogleTasksItem", "Google Tasks")
    }
  end

  before { item_classes }

  it "seeds idempotent item snapshots and only publishable mappings" do
    confirmed = SyncCollection.create!(title: "Buy milk", mapping_method: "source_sync_id", mapping_confidence: "high")
    withheld = SyncCollection.create!(title: "Release", mapping_method: "title_fallback", mapping_confidence: "low")
    create_item(:asana, "asana-1", confirmed)
    create_item(:omnifocus, "of-1", confirmed)
    create_item(:github, "issue-1", withheld)
    create_item(:google_tasks, "google-1", withheld)

    summary = described_class.run!(backfilled_at:)

    expect(summary).to include(
      item_snapshots: { "asana" => 1, "omnifocus" => 1, "github" => 1, "google_tasks" => 1 },
      mappings: { "high" => 2 },
      skipped: { "low_confidence_mappings" => 2 }
    )
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(2)
    expect(OutboxEntry.where(record_kind: %w[observation sync_run])).to be_empty

    omnifocus_row = OutboxEntry.find_by(record_kind: "item", service_type: "omnifocus")
    expect(omnifocus_row.service_instance).to eq("omnifocus:default")
    expect(omnifocus_row.payload).to include(
      "contract_version" => 1,
      "observed_at" => omnifocus_row.observed_at.utc.iso8601(6),
      "provenance" => hash_including(
        "detected_by" => "backfill",
        "baseline" => true,
        "backfilled_at" => backfilled_at.utc.iso8601(6)
      )
    )

    expect { described_class.run!(backfilled_at: backfilled_at + 1.day) }
      .not_to(change(OutboxEntry, :count))
  end

  it "reports incomplete and withheld data without writing in dry-run mode" do
    collection = SyncCollection.create!(title: "Uncertain", mapping_method: "manual_backfill", mapping_confidence: "low")
    create_item(:github, "issue-2", collection)
    item_classes[:asana].create!(title: "Incomplete")

    summary = described_class.run!(dry_run: true, backfilled_at:)

    expect(summary).to include(
      item_snapshots: { "github" => 1 },
      mappings: {},
      skipped: { "incomplete_items" => 1, "low_confidence_mappings" => 1 }
    )
    expect(OutboxEntry.all).to be_empty
  end

  private

  def stub_item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_method(:external_data) { {} }

      define_singleton_method(:attribute_map) { {} }
    end)
  end

  def create_item(service, external_id, collection)
    item_classes.fetch(service).create!(
      title: collection.title,
      external_id:,
      sync_collection: collection,
      options: options.merge(service_name: service.to_s.camelize)
    )
  end
end
