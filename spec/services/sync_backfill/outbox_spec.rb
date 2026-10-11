# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Outbox do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:item_classes) do
    {
      omnifocus: stub_item_class("BackfillOmnifocusItem", "Omnifocus"),
      asana: stub_item_class("BackfillAsanaItem", "Asana"),
      github: stub_item_class("BackfillGithubItem", "Github"),
      google_tasks: stub_item_class("BackfillGoogleTasksItem", "Google Tasks")
    }
  end

  before { item_classes }

  it "seeds idempotent baseline snapshots and only publishable mapping memberships" do
    high = collection_with("high")
    medium = collection_with("medium")
    low = collection_with("low")
    omnifocus = create_item(:omnifocus, high)
    asana = create_item(:asana, high)
    github = create_item(:github, medium)
    google_tasks = create_item(:google_tasks, low)

    summary = described_class.run!
    described_class.run!

    expect(summary).to include(
      items: { "omnifocus" => 1, "asana" => 1, "github" => 1, "google_tasks" => 1 },
      mappings: { "high" => 2, "medium" => 1 },
      withheld_mappings: { "low" => 1 },
      skipped: {}
    )
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(3)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty

    item_rows = OutboxEntry.where(record_kind: "item").order(:external_id)
    expect(item_rows.pluck(:service_instance)).to all(end_with(":default"))
    expect(item_rows.map { |row| row.payload.dig("provenance", "detected_by") }).to all(eq("backfill"))
    expect(item_rows.map { |row| row.payload.dig("provenance", "baseline") }).to all(eq(true))
    expect(item_rows.map { |row| row.payload.dig("provenance", "backfilled_at") }).to all(eq(observed_at.iso8601(6)))
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to match_array(
      [omnifocus, asana, github].map(&:external_id)
    )
    expect(OutboxEntry.where(record_kind: "mapping").map { |row| row.payload["mapping_confidence"] })
      .to contain_exactly("confirmed", "confirmed", "inferred")
    expect(google_tasks.reload.source_service_name).to eq("Google Tasks")
  end

  it "summarizes incomplete records without mutating data in dry-run mode" do
    item = item_classes.fetch(:asana).create!(title: "Incomplete", external_id: nil, options: item_options("Asana"))
    item.update_columns(last_observed_at: nil)
    collection = collection_with("high")
    item.update_columns(sync_collection_id: collection.id)

    summary = described_class.run!(dry_run: true)

    expect(summary[:skipped]).to eq(missing_external_id: 1, mapping_missing_external_id: 1)
    expect(item.reload.last_observed_at).to be_nil
    expect(OutboxEntry.count).to eq(0)
  end

  private

  def stub_item_class(constant, provider)
    stub_const(constant, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_singleton_method(:attribute_map) { {} }

      define_method(:external_data) { {} }
    end)
  end

  def collection_with(confidence)
    SyncCollection.create!(
      title: "Collection #{confidence}",
      mapping_method: confidence == "low" ? "title_fallback" : "source_sync_id",
      mapping_confidence: confidence,
      mapping_metadata: { "backfill" => true },
      mapping_established_at: observed_at,
      mapping_last_observed_at: observed_at
    )
  end

  def create_item(service, collection)
    item = item_classes.fetch(service).create!(
      title: "#{service} task",
      external_id: "#{service}-1",
      sync_collection: collection,
      last_modified: observed_at,
      options: item_options(item_classes.fetch(service).new.provider)
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
      updated_at: observed_at
    )
    item
  end

  def item_options(service_name)
    { service_name:, services: [], primary: "Asana", tags: [] }
  end
end
