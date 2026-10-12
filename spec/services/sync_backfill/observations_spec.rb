# frozen_string_literal: true

require "rails_helper"
require "stringio"

RSpec.describe SyncBackfill::Observations, :full_options do
  let(:output) { StringIO.new }
  let(:item_classes) do
    {
      asana: item_class("BackfillAsanaItem", "Asana"),
      omnifocus: item_class("BackfillOmniFocusItem", "OmniFocus"),
      github: item_class("BackfillGithubItem", "Github"),
      google_tasks: item_class("BackfillGoogleTasksItem", "GoogleTasks")
    }
  end

  before { item_classes }

  it "seeds idempotent baseline snapshots and publishes only non-low-confidence mappings" do
    high_confidence = SyncCollection.create!(title: "Verified", mapping_method: "source_sync_id", mapping_confidence: "high")
    inferred = SyncCollection.create!(title: "Inferred", mapping_method: "title_fallback", mapping_confidence: "medium")
    low_confidence = SyncCollection.create!(title: "Needs review", mapping_method: "manual_backfill", mapping_confidence: "low")
    create_item(:asana, "asana-1", high_confidence)
    create_item(:omnifocus, "of-1", high_confidence)
    create_item(:github, "gh-1", inferred)
    create_item(:google_tasks, "gt-1", inferred)
    create_item(:asana, "incomplete", low_confidence, external_id: nil)

    described_class.run!(output:)
    first_summary = JSON.parse(output.string)

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:sync_collection_id)).not_to include(low_confidence.id)
    expect(OutboxEntry.where(record_kind: "item").pluck(:service_instance)).to include(
      "asana:default", "omnifocus:default", "github:default", "google_tasks:default"
    )
    expect(OutboxEntry.where(record_kind: "item").first.payload.fetch("provenance")).to include("detected_by" => "backfill")
    expect(first_summary).to include(
      "dry_run" => false,
      "confidence" => include("high" => 1, "medium" => 1, "low" => 1),
      "skipped" => include("incomplete_items" => 1)
    )

    expect { described_class.run!(output: StringIO.new) }
      .not_to(change { OutboxEntry.count })
  end

  it "reports a dry run without modifying sync records or the outbox" do
    item = create_item(:asana, "asana-dry-run")
    item.update_columns(last_snapshot: nil)

    expect { described_class.run!(dry_run: true, output:) }.not_to(change { OutboxEntry.count })

    expect(item.reload.last_snapshot).to be_nil
    expect(JSON.parse(output.string)).to include("dry_run" => true, "items" => include("considered" => 1))
  end

  private

  def item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_method(:external_data) { {} }

      define_singleton_method(:attribute_map) { {} }
    end)
  end

  def create_item(service, identifier, collection = nil, external_id: identifier)
    item_classes.fetch(service).create!(
      title: identifier,
      external_id:,
      sync_collection: collection,
      options: { service_name: item_classes.fetch(service).name.delete_suffix("Item").delete_prefix("Backfill"), services: [], primary: "Asana", tags: [] }
    )
  end
end
