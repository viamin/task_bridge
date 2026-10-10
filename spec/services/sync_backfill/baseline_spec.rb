# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Baseline do
  let(:asana_item_class) do
    stub_const("BaselineSpecAsanaItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Asana"
      end

      def external_data
        {}
      end
    end)
  end
  let(:omnifocus_item_class) do
    stub_const("BaselineSpecOmnifocusItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Omnifocus"
      end

      def external_data
        {}
      end
    end)
  end
  let(:options) do
    { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] }
  end
  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let!(:confirmed_collection) do
    SyncCollection.create!(title: "Confirmed pair", mapping_method: "source_sync_id", mapping_confidence: "high")
  end
  let!(:tentative_collection) do
    SyncCollection.create!(title: "Tentative pair", mapping_method: "title_fallback", mapping_confidence: "medium")
  end

  def create_item(item_class, external_id, collection: nil)
    item_class.create!(
      options:,
      external_id:,
      title: "Item #{external_id}",
      completed: false,
      sync_collection: collection
    ).tap { |item| item.update_columns(last_observed_at: observed_at, first_observed_at: observed_at) }
  end

  before do
    asana_item_class
    omnifocus_item_class
    create_item(asana_item_class, "asana-1", collection: confirmed_collection)
    create_item(omnifocus_item_class, "of-1", collection: confirmed_collection)
    create_item(asana_item_class, "asana-2", collection: tentative_collection)
    create_item(omnifocus_item_class, "of-2", collection: tentative_collection)
  end

  it "seeds one item snapshot row per known source item and mapping rows for confirmed memberships" do
    summary = described_class.run!

    expect(summary).to eq(items: 4, mappings: 2)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    item_keys = OutboxEntry.where(record_kind: "item").map { |row| row.payload["item_key"] }
    expect(item_keys).to contain_exactly("asana:asana-1", "asana:asana-2", "omnifocus:of-1", "omnifocus:of-2")

    mapping_rows = OutboxEntry.where(record_kind: "mapping")
    expect(mapping_rows.map(&:sync_collection_id)).to all(eq(confirmed_collection.id))
    expect(mapping_rows.map(&:external_id)).to contain_exactly("asana-1", "of-1")
  end

  it "withholds tentative mappings per the RDR's safer backfill default" do
    described_class.run!

    expect(OutboxEntry.where(record_kind: "mapping", sync_collection_id: tentative_collection.id)).to be_empty
  end

  it "is idempotent: reruns reuse the same deterministic rows" do
    described_class.run!
    described_class.run!

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(2)
  end

  it "shares the identity spine with observation rows" do
    described_class.run!
    asana_item = asana_item_class.find_by!(external_id: "asana-1")
    Outbox::ObservationEmitter.emit_for_item(asana_item, previous_snapshot: nil, observed_at:)

    observation_row = OutboxEntry.find_by!(record_kind: "observation", external_id: "asana-1")
    item_row = OutboxEntry.find_by!(record_kind: "item", external_id: "asana-1")
    expect(item_row.service_instance).to eq(observation_row.service_instance)
    expect(item_row.payload["item_key"]).to eq(observation_row.payload["item_key"])
  end
end
