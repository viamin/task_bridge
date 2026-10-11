# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-11T10:00:00Z") }
  let(:options) { { quiet: true, pretend: false, services: [], primary: "Asana", tags: [] } }

  def item_class_for(provider)
    class_name = "Backfill#{provider.delete('_')}Item"
    return class_name.constantize if class_name.safe_constantize

    stub_const(class_name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end)
  end

  def create_item(provider, external_id:, collection: nil)
    item_class_for(provider).create!(
      title: "#{provider} task",
      external_id:,
      sync_collection: collection,
      last_modified: observed_at,
      options: options.merge(service_name: provider)
    )
  end

  it "seeds stable baseline snapshots for OmniFocus, Asana, GitHub, and Google Tasks" do
    items = %w[Omnifocus Asana Github GoogleTasks].map do |provider|
      create_item(provider, external_id: "#{provider.downcase}-1")
    end

    travel_to(observed_at) { described_class.run! }

    rows = OutboxEntry.where(record_kind: "item").order(:external_id)
    expect(rows.map(&:service_type)).to contain_exactly("omnifocus", "asana", "github", "google_tasks")
    expect(rows.map(&:service_instance)).to contain_exactly(
      "omnifocus:default", "asana:default", "github:default", "google_tasks:default"
    )
    expect(rows.map { |row| row.payload.dig("provenance", "detected_by") }).to all(eq("backfill"))
    expect(rows.map { |row| row.payload.dig("provenance", "baseline") }).to all(be(true))
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)

    expect { travel_to(observed_at + 1.hour) { described_class.run! } }
      .not_to(change { OutboxEntry.where(record_kind: "item").count })
  end

  it "publishes inferred mappings and withholds tentative mappings" do
    inferred = SyncCollection.create!(title: "Inferred", mapping_method: "title_fallback", mapping_confidence: "medium")
    tentative = SyncCollection.create!(title: "Tentative", mapping_method: "manual_backfill", mapping_confidence: "low")
    create_item("Asana", external_id: "asana-1", collection: inferred)
    create_item("Github", external_id: "github-1", collection: inferred)
    create_item("Omnifocus", external_id: "omnifocus-1", collection: tentative)

    summary = travel_to(observed_at) { described_class.run! }

    mapping_rows = OutboxEntry.where(record_kind: "mapping")
    expect(mapping_rows.map { |row| row.payload["mapping_confidence"] }).to all(eq("inferred"))
    expect(mapping_rows.map(&:sync_collection_id)).to all(eq(inferred.id))
    expect(summary[:mappings]).to eq("inferred" => 2)
    expect(summary[:skipped]).to include(low_confidence_mappings: 1)
  end

  it "reports incomplete records without writing during a dry run" do
    create_item("Asana", external_id: "asana-1")
    item_class_for("Github").create!(title: "Incomplete", options: options.merge(service_name: "Github"))

    summary = described_class.run!(dry_run: true, backfilled_at: observed_at)

    expect(summary[:items]).to include("asana" => 1)
    expect(summary[:skipped]).to include(items_missing_external_id: 1)
    expect(OutboxEntry.all).to be_empty
  end
end
