# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline, :full_options do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:item_class) do
    sync_item_class("OutboxBaselineAsanaItem", "Asana")
  end

  before { item_class }

  it "enqueues baseline item snapshots idempotently without observations" do
    item = item_class.create!(title: "Buy milk", external_id: "asana-1", options: options.merge(service_name: "Asana"))

    travel_to(now) do
      described_class.run!
      described_class.run!
    end

    row = OutboxEntry.find_by!(record_kind: "item")
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(row.service_instance).to eq("asana:default")
    expect(row.payload.dig("provenance", "detected_by")).to eq("backfill")
    expect(row.payload.dig("provenance", "baseline")).to be(true)
    expect(row.payload.dig("provenance", "backfilled_at")).to eq("2026-10-11T12:00:00.000000Z")
    expect(row.payload["observed_at"]).to eq(item.reload.last_observed_at.utc.iso8601(6))
  end

  it "publishes confirmed and inferred mappings while withholding low-confidence mappings" do
    high = SyncCollection.create!(title: "High", mapping_method: "source_sync_id", mapping_confidence: "high")
    medium = SyncCollection.create!(title: "Medium", mapping_method: "created_by_sync", mapping_confidence: "medium")
    low = SyncCollection.create!(title: "Low", mapping_method: "title_fallback", mapping_confidence: "low")
    [high, medium, low].each_with_index do |collection, index|
      item_class.create!(title: collection.title, external_id: "asana-#{index}", sync_collection: collection,
                         options: options.merge(service_name: "Asana"))
    end

    summary = travel_to(now) { described_class.run! }

    expect(OutboxEntry.where(record_kind: "mapping").pluck(:sync_collection_id)).to contain_exactly(high.id, medium.id)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:payload).map { |payload| payload["mapping_confidence"] })
      .to contain_exactly("confirmed", "inferred")
    expect(summary.dig(:mappings, :withheld_by_confidence)).to include("low" => 1)
  end

  it "backfills representative OmniFocus, Asana, GitHub, and Google Tasks records" do
    [
      [item_class, "Asana", "asana-1"],
      [sync_item_class("OutboxBaselineOmniFocusItem", "Omnifocus"), "OmniFocus", "of-1"],
      [sync_item_class("OutboxBaselineGithubItem", "Github"), "Github:repo", "gh-1"],
      [sync_item_class("OutboxBaselineGoogleTasksItem", "Google Tasks"), "Google Tasks", "gt-1"]
    ].each do |klass, service_name, external_id|
      klass.create!(title: service_name, external_id:, options: options.merge(service_name:))
    end

    described_class.run!(now:)

    expect(OutboxEntry.where(record_kind: "item").pluck(:service_type))
      .to contain_exactly("asana", "omnifocus", "github", "google_tasks")
  end

  it "reports candidates without writing in dry-run mode" do
    [
      [item_class, "Asana", "asana-1"],
      [sync_item_class("OutboxBaselineOmniFocusItem", "Omnifocus"), "OmniFocus", "of-1"],
      [sync_item_class("OutboxBaselineGithubItem", "Github"), "Github:repo", "gh-1"],
      [sync_item_class("OutboxBaselineGoogleTasksItem", "Google Tasks"), "Google Tasks", "gt-1"]
    ].each do |klass, service_name, external_id|
      klass.create!(title: service_name, external_id:, options: options.merge(service_name:))
    end
    item_class.create!(title: "Incomplete", options: options.merge(service_name: "Asana"))

    summary = described_class.run!(dry_run: true, now:)

    expect(OutboxEntry.count).to be_zero
    expect(summary.dig(:items, :candidates_by_service)).to include(
      "asana" => 1, "omnifocus" => 1, "github" => 1, "google_tasks" => 1
    )
    expect(summary.dig(:items, :skipped)).to include("asana:missing_external_id" => 1)
  end

  it "reports inferred low-confidence memberships without persisting their provenance" do
    collection = SyncCollection.create!(title: "Unmatched")
    item_class.create!(title: "Unmatched", external_id: "asana-1", sync_collection: collection,
                       options: options.merge(service_name: "Asana"))

    summary = described_class.run!(dry_run: true, now:)

    expect(collection.reload.mapping_confidence).to be_nil
    expect(summary.dig(:mappings, :withheld_by_confidence)).to include("low" => 1)
  end

  def sync_item_class(constant_name, provider_name)
    stub_const(constant_name, Class.new(Base::SyncItem) do
      define_singleton_method(:attribute_map) { {} }
      define_method(:provider) { provider_name }
      define_method(:external_data) { {} }
    end)
  end
end
