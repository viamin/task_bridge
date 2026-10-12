# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::Backfill do
  include ActiveSupport::Testing::TimeHelpers

  let(:backfilled_at) { Time.zone.parse("2026-10-12T10:00:00Z") }
  let(:collection) { SyncCollection.create!(title: "Existing work") }

  before do
    stub_service_item("BackfillOmniFocusItem", "Omnifocus")
    stub_service_item("BackfillAsanaItem", "Asana")
    stub_service_item("BackfillGithubItem", "Github")
    stub_service_item("BackfillGoogleTasksItem", "GoogleTasks")
  end

  it "seeds stable baseline snapshots for representative services without observations" do
    items = [
      create_item(BackfillOmniFocusItem, "of-1"),
      create_item(BackfillAsanaItem, "asana-1", service_name: "Asana:work"),
      create_item(BackfillGithubItem, "gh-1"),
      create_item(BackfillGoogleTasksItem, "gt-1")
    ]

    described_class.run!(backfilled_at:)
    described_class.run!(backfilled_at: (backfilled_at + 1.hour))

    rows = OutboxEntry.where(record_kind: "item").order(:external_id)
    expect(rows.size).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(rows.map(&:service_instance)).to contain_exactly("omnifocus:default", "asana:work", "github:default", "google_tasks:default")
    expect(rows.map { |row| row.payload.dig("provenance", "detected_by") }).to all(eq("backfill"))
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)
  end

  it "publishes only confirmed and inferred memberships and reports held and incomplete records" do
    confirmed = create_item(BackfillAsanaItem, "asana-1", collection:)
    inferred = create_item(BackfillGithubItem, "gh-1", collection:)
    BackfillGoogleTasksItem.create!(title: "missing identifier")
    collection.update!(mapping_method: "source_sync_id", mapping_confidence: "high")
    low_collection = SyncCollection.create!(title: "Needs review", mapping_method: "manual_backfill", mapping_confidence: "low")
    low = create_item(BackfillOmniFocusItem, "of-1", collection: low_collection)

    summary = described_class.run!(backfilled_at:)

    expect(OutboxEntry.where(record_kind: "mapping").map(&:external_id)).to contain_exactly(confirmed.external_id, inferred.external_id)
    expect(summary.dig(:by_confidence, "low", :mappings_withheld)).to eq(1)
    expect(summary.dig(:by_service, "google_tasks", :items_skipped_incomplete)).to eq(1)
    expect(low.reload.last_snapshot).to be_present
  end

  it "does not write during a dry run" do
    item = create_item(BackfillOmniFocusItem, "of-1")
    item.update_columns(source_service_name: nil, source_service_instance: nil, last_observed_at: nil)

    summary = described_class.run!(dry_run: true, backfilled_at:)

    expect(summary.dig(:by_service, "omnifocus", :items)).to eq(1)
    expect(OutboxEntry.count).to eq(0)
    expect(item.reload.source_service_name).to be_nil
  end

  private

  def stub_service_item(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_singleton_method(:attribute_map) { {} }
      define_method(:external_data) { {} }
    end)
  end

  def create_item(klass, external_id, service_name: nil, collection: nil)
    klass.create!(
      title: "Existing work",
      external_id:,
      sync_collection: collection,
      options: { service_name:, services: [], primary: "Omnifocus", tags: [] }.compact
    )
  end
end
