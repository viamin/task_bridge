# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::ObservationBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:options) { { services: [], primary: "Omnifocus", tags: [] } }

  def item_class_for(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end)
  end

  def create_item(item_class, provider, collection)
    item_class.create!(
      external_id: "#{provider.downcase}-42",
      title: "Release checklist",
      notes: "#{provider.downcase}_id: #{provider.downcase}-42",
      sync_collection: collection,
      options: options.merge(service_name: provider)
    )
  end

  it "creates idempotent baseline snapshots and mappings for existing provider records" do
    collection = SyncCollection.create!(
      title: "Release checklist",
      mapping_method: "source_sync_id",
      mapping_confidence: "high"
    )
    providers = {
      "BaselineOmnifocusItem" => "Omnifocus",
      "BaselineAsanaItem" => "Asana",
      "BaselineGithubItem" => "Github",
      "BaselineGoogleTasksItem" => "GoogleTasks"
    }
    items = providers.map { |name, provider| create_item(item_class_for(name, provider), provider, collection) }

    travel_to(observed_at) do
      first_summary = described_class.run!
      second_summary = described_class.run!

      expect(first_summary[:services].keys).to contain_exactly("omnifocus", "asana", "github", "google_tasks")
      expect(second_summary[:services]).to eq(first_summary[:services])
    end

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "item").pluck(:service_instance))
      .to contain_exactly("omnifocus:default", "asana:default", "github:default", "google_tasks:default")
    expect(OutboxEntry.where(record_kind: "item").map { |row| row.payload.dig("provenance", "detected_by") })
      .to all(eq("backfill"))
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)
  end

  it "withholds low-confidence mappings and leaves all records untouched in dry-run mode" do
    collection = SyncCollection.create!(
      title: "Uncertain match",
      mapping_method: "manual_backfill",
      mapping_confidence: "low"
    )
    item = create_item(item_class_for("BaselineLowConfidenceItem", "Asana"), "Asana", collection)

    summary = described_class.run!(dry_run: true, backfilled_at: observed_at)

    expect(summary[:confidence]).to include("low" => 1)
    expect(summary[:skipped]).to include(low_confidence_mapping: 1)
    expect(OutboxEntry.count).to eq(0)
    expect(item.reload.last_snapshot).to be_nil
  end
end
