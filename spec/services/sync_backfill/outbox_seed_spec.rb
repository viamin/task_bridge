# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxSeed do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:item_class) do
    stub_const("OutboxSeedSpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def external_data
        {}
      end

      def provider
        source_service_type || "OmniFocus"
      end
    end)
  end

  before { item_class }

  def item(provider:, external_id:, collection:, service_name: nil)
    item_class.create!(
      title: "Baseline #{provider}", external_id:, sync_collection: collection,
      options: { service_name: service_name || provider, services: [], primary: "Asana", tags: [] },
      source_service_type: provider, last_modified: observed_at
    )
  end

  it "seeds idempotent baseline snapshots for OmniFocus, Asana, GitHub, and Google Tasks" do
    collection = SyncCollection.create!(title: "Baseline", mapping_method: "source_sync_id", mapping_confidence: "high")
    %w[OmniFocus Asana Github GoogleTasks].each_with_index do |provider, index|
      item(provider:, external_id: "id-#{index}", collection:, service_name: provider == "Asana" ? "Asana:work" : provider)
    end

    travel_to(observed_at + 1.day) { described_class.run! }
    travel_to(observed_at + 2.days) { described_class.run! }

    expect(OutboxEntry.where(record_kind: "item")).to have_attributes(count: 4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "item").pluck(:service_instance)).to include(
      "omni_focus:default", "asana:work", "github:default", "google_tasks:default"
    )
    expect(OutboxEntry.where(record_kind: "item").first.payload["provenance"]).to include(
      "detected_by" => "backfill", "baseline" => true
    )
  end

  it "reports low confidence mappings without writing them during a dry run" do
    collection = SyncCollection.create!(title: "Uncertain", mapping_method: "title_fallback", mapping_confidence: "low")
    item(provider: "OmniFocus", external_id: "of-1", collection:)

    summary = described_class.run!(dry_run: true, output: StringIO.new)

    expect(summary).to include("items.omni_focus" => 1, "mappings_low.omni_focus" => 1,
                               "mappings_withheld_low.omni_focus" => 1)
    expect(OutboxEntry.count).to eq(0)
  end
end
