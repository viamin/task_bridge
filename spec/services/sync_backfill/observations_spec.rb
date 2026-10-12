# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Observations do
  let(:backfilled_at) { Time.zone.parse("2026-10-12T12:00:00Z") }
  let(:collection) { SyncCollection.create!(title: "Release") }
  let(:title_collection) { SyncCollection.create!(title: "Review") }
  let(:low_collection) { SyncCollection.create!(title: "Uncertain") }

  before do
    create_item("Omnifocus", "of-1", "Release", "asana_id: as-1", collection)
    create_item("Asana", "as-1", "Release", "omnifocus_id: of-1", collection)
    create_item("Github", "gh-1", "Review", nil, title_collection)
    create_item("GoogleTasks", "gt-1", "Review", nil, title_collection)
    create_item("Github", "gh-low", "Uncertain", nil, low_collection)
  end

  it "backfills representative source snapshots and only publishable mapping evidence idempotently" do
    first = described_class.run!(backfilled_at:)
    second = described_class.run!(backfilled_at: backfilled_at + 1.day)

    expect(first).to include(
      items_by_service: { "omnifocus" => 1, "asana" => 1, "github" => 2, "google_tasks" => 1 },
      mappings_by_confidence: { "high" => 2, "medium" => 2, "low" => 1 },
      skipped: { "mappings.low_confidence" => 1 }
    )
    expect(second).to eq(first)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(5)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:sync_collection_id)).not_to include(low_collection.id)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:payload).map { |payload| payload["mapping_confidence"] })
      .to contain_exactly("confirmed", "confirmed", "inferred", "inferred")

    item = OutboxEntry.find_by!(record_kind: "item", external_id: "of-1")
    expect(item.service_instance).to eq("omnifocus:default")
    expect(item.payload).to include(
      "provenance" => include("detected_by" => "backfill", "backfilled_at" => "2026-10-12T12:00:00.000000Z")
    )
  end

  it "reports planned rows without mutating source or outbox data in dry-run mode" do
    report = described_class.run!(dry_run: true, backfilled_at:)

    expect(report.fetch(:items_by_service)).to include("omnifocus" => 1, "asana" => 1, "github" => 2, "google_tasks" => 1)
    expect(report.fetch(:mappings_by_confidence)).to include("high" => 2, "medium" => 2, "low" => 1)
    expect(OutboxEntry.count).to eq(0)
    expect(Base::SyncItem.where.not(source_service_name: nil)).to be_empty
  end

  private

  def create_item(provider, external_id, title, notes, sync_collection)
    item_class = Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_singleton_method(:attribute_map) { {} }

      define_method(:external_data) { {} }
    end
    stub_const("Backfill#{provider}#{external_id.delete('-').capitalize}", item_class)
    item = item_class.create!(external_id:, title:, notes:, sync_collection:,
                              options: { service_name: provider, services: [], primary: "Asana", tags: [] })
    item.update_columns(source_service_name: nil, source_service_instance: nil, source_service_type: nil,
                        source_external_id: nil, source_url: nil, source_updated_at: nil,
                        first_observed_at: nil, last_observed_at: nil, source_metadata: nil)
  end
end
