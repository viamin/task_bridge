# frozen_string_literal: true

require "rails_helper"
require "stringio"

RSpec.describe SyncBackfill::Baseline, :full_options do
  let(:output) { StringIO.new }
  let(:item_classes) do
    %w[Omnifocus Asana Github GoogleTasks].to_h do |provider|
      [provider, stub_const("Baseline#{provider}Item", Class.new(Base::SyncItem) do
        define_method(:provider) { provider }

        define_singleton_method(:attribute_map) { {} }
        define_method(:external_data) { {} }
      end)]
    end
  end

  before { item_classes }

  it "seeds idempotent baseline snapshots and representative mapping memberships" do
    high_confidence = SyncCollection.create!(title: "Buy milk")
    inferred = SyncCollection.create!(title: "Release checklist")
    items = [
      item_classes.fetch("Omnifocus").create!(title: "Buy milk", external_id: "of-1", notes: "asana_id: asana-1",
                                              sync_collection: high_confidence),
      item_classes.fetch("Asana").create!(title: "Buy milk", external_id: "asana-1", notes: "omnifocus_id: of-1",
                                          sync_collection: high_confidence),
      item_classes.fetch("Github").create!(title: "Release checklist", external_id: "gh-1", sync_collection: inferred),
      item_classes.fetch("GoogleTasks").create!(title: "Release checklist", external_id: "gt-1", sync_collection: inferred)
    ]

    described_class.run!(output:)

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "item").map { |row| row.payload.dig("provenance", "detected_by") }).to all(eq("backfill"))
    expect(OutboxEntry.find_by(record_kind: "item", external_id: "of-1").service_instance).to eq("omnifocus:default")
    expect(inferred.reload.mapping_confidence).to eq("medium")

    described_class.run!(output:)

    expect(OutboxEntry.where(record_kind: "item").count).to eq(items.size)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(items.size)
  end

  it "reports and withholds low-confidence mappings in a dry run without writes" do
    collection = SyncCollection.create!(title: "Unpaired")
    item_classes.fetch("Github").create!(title: "Unpaired", external_id: "gh-2", sync_collection: collection)

    described_class.run!(dry_run: true, output:)

    expect(OutboxEntry.count).to eq(0)
    expect(output.string).to include("github=1", "low=1", "Withheld low-confidence mappings: 1")
  end
end
