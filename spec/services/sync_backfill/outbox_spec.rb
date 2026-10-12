# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Outbox do
  include ActiveSupport::Testing::TimeHelpers

  let(:backfilled_at) { Time.zone.parse("2026-10-12T12:00:00Z") }
  let(:collection) { SyncCollection.create!(title: "Release checklist") }

  def item_class(constant_name, provider_name)
    stub_const(constant_name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider_name }

      define_singleton_method(:attribute_map) { {} }

      define_method(:external_data) { {} }
    end)
  end

  def create_item(klass, external_id)
    klass.create!(
      title: "Release checklist",
      external_id:,
      sync_collection: collection,
      options: { service_name: klass.new.provider, services: [], primary: "Omnifocus", tags: [] }
    )
  end

  it "seeds idempotent baseline snapshots for OmniFocus, Asana, GitHub, and Google Tasks" do
    omnifocus = create_item(item_class("BackfillOmniFocusItem", "Omnifocus"), "of-1")
    asana = create_item(item_class("BackfillAsanaItem", "Asana"), "asana-1")
    github = create_item(item_class("BackfillGithubItem", "Github"), "gh-1")
    google_tasks = create_item(item_class("BackfillGoogleTasksItem", "GoogleTasks"), "gt-1")

    first_summary = described_class.run!(backfilled_at:)
    second_summary = described_class.run!(backfilled_at:)

    expect(first_summary[:items]).to eq(
      "omnifocus" => 1, "asana" => 1, "github" => 1, "google_tasks" => 1
    )
    expect(second_summary[:items]).to eq(first_summary[:items])
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty

    [omnifocus, asana, github, google_tasks].each do |item|
      snapshot = item.reload.last_snapshot
      row = OutboxEntry.find_by!(record_kind: "item", external_id: item.external_id)

      expect(snapshot).to include("title" => "Release checklist")
      expect(row.payload.dig("provenance", "detected_by")).to eq("backfill")
      expect(row.payload.dig("provenance", "backfilled_at")).to eq("2026-10-12T12:00:00.000000Z")
      expect(row.service_instance).to eq("#{row.service_type}:default")
    end
  end

  it "publishes inferred mappings and withholds low-confidence memberships" do
    high_collection = SyncCollection.create!(
      title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high",
      mapping_last_observed_at: backfilled_at
    )
    low_collection = SyncCollection.create!(
      title: "Needs review", mapping_method: "manual_backfill", mapping_confidence: "low"
    )
    item_class = item_class("BackfillMappingItem", "Asana")
    create_item(item_class, "inferred-1")
    create_item(item_class("BackfillMappingPeerItem", "Github"), "inferred-2")
    item_class.create!(title: "Confirmed", external_id: "confirmed-1", sync_collection: high_collection)
    item_class.create!(title: "Needs review", external_id: "review-1", sync_collection: low_collection)

    summary = described_class.run!(backfilled_at:)

    expect(summary[:mappings]).to include("medium" => 2, "high" => 1)
    expect(summary[:withheld_mappings]).to include("low" => 1)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id))
      .to contain_exactly("inferred-1", "inferred-2", "confirmed-1")
    expect(OutboxEntry.find_by!(record_kind: "mapping", external_id: "inferred-1").payload["mapping_confidence"])
      .to eq("inferred")
  end

  it "reports without writing when dry run is requested" do
    item = create_item(item_class("BackfillDryRunItem", "Omnifocus"), "of-1")
    observed_at = item.last_observed_at

    summary = described_class.run!(dry_run: true, backfilled_at:)

    expect(summary[:items]).to eq("omnifocus" => 1)
    expect(OutboxEntry.count).to eq(0)
    expect(item.reload.last_observed_at).to eq(observed_at)
  end
end
