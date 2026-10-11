# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Outbox do
  let(:item_classes) do
    {
      omnifocus: build_item_class("BackfillOmniFocusItem", "Omnifocus"),
      asana: build_item_class("BackfillAsanaItem", "Asana"),
      github: build_item_class("BackfillGithubItem", "Github"),
      google_tasks: build_item_class("BackfillGoogleTasksItem", "GoogleTasks")
    }
  end
  let(:options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }
  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }

  before { item_classes }

  it "backfills idempotent baseline snapshots for OmniFocus, Asana, GitHub, and Google Tasks" do
    high_confidence = SyncCollection.create!(title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high")
    medium_confidence = SyncCollection.create!(title: "Inferred", mapping_method: "title_fallback", mapping_confidence: "medium")
    low_confidence = SyncCollection.create!(title: "Tentative", mapping_method: "manual_backfill", mapping_confidence: "low")
    create_item(:omnifocus, high_confidence, "of-1")
    create_item(:asana, high_confidence, "asana-1")
    create_item(:github, medium_confidence, "gh-1")
    create_item(:google_tasks, low_confidence, "gt-1")

    summary = described_class.run!(now: observed_at)
    rerun_summary = described_class.run!(now: observed_at + 1.hour)

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(3)
    expect(OutboxEntry.where(record_kind: "item").pluck(:service_instance)).to contain_exactly(
      "omnifocus:default", "asana:default", "github:default", "google_tasks:default"
    )
    expect(OutboxEntry.where(record_kind: "item").first.payload.fetch("provenance")).to include(
      "detected_by" => "backfill", "backfilled_at" => observed_at.utc.iso8601(6)
    )
    expect(summary).to include(items: { "omnifocus" => 1, "asana" => 1, "github" => 1, "google_tasks" => 1 },
                               mappings: { "high" => 2, "medium" => 1 },
                               skipped: { "mappings_low" => 1 })
    expect(rerun_summary).to include(summary)
    expect(OutboxEntry.count).to eq(7)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:payload).map { |payload| payload["mapping_confidence"] })
      .to contain_exactly("confirmed", "confirmed", "inferred")
  end

  it "summarizes a dry run without writing provenance or outbox rows" do
    collection = SyncCollection.create!(title: "Incomplete")
    item = create_item(:asana, collection, "asana-dry-run")
    item.update_columns(source_service_name: nil, source_service_type: nil, source_external_id: nil, last_observed_at: nil)

    summary = described_class.run!(dry_run: true, now: observed_at)

    expect(summary).to include(items: { "asana" => 1 }, skipped: { "mappings_incomplete" => 1 })
    expect(item.reload.source_service_name).to be_nil
    expect(OutboxEntry.count).to eq(0)
  end

  private

  def build_item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }
      define_method(:external_data) { {} }

      def self.attribute_map
        {}
      end
    end)
  end

  def create_item(provider, collection, external_id)
    item_classes.fetch(provider).create!(
      title: "#{provider} baseline",
      external_id:,
      sync_collection: collection,
      options:
    )
  end
end
