# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Baseline do
  let(:now) { Time.zone.parse("2026-10-11T12:00:00Z") }

  before do
    stub_item("BaselineOmniFocusItem", "Omnifocus")
    stub_item("BaselineAsanaItem", "Asana")
    stub_item("BaselineGithubItem", "Github")
    stub_item("BaselineGoogleTasksItem", "Google Tasks")
  end

  it "seeds idempotent baseline snapshots and withholds low-confidence mappings" do
    confirmed = collection_with("source_sync_id", "high", BaselineAsanaItem, BaselineGithubItem)
    inferred = collection_with("title_fallback", "medium", BaselineOmniFocusItem, BaselineGoogleTasksItem)
    low = collection_with("manual_backfill", "low", BaselineAsanaItem, BaselineOmniFocusItem)

    summary = described_class.run!(now:)

    expect(OutboxEntry.where(record_kind: "item").count).to eq(6)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(summary.dig(:mappings, :by_confidence)).to include("confirmed" => 2, "inferred" => 2)
    expect(summary.dig(:mappings, :withheld_by_confidence)).to eq("tentative" => 2)

    snapshot = OutboxEntry.find_by(record_kind: "item", external_id: confirmed.first.external_id)
    expect(snapshot.service_instance).to eq("asana:work")
    expect(snapshot.payload.fetch("provenance")).to include(
      "detected_by" => "backfill", "baseline" => true, "backfilled_at" => now.iso8601(6)
    )
    expect(OutboxEntry.find_by(record_kind: "item", external_id: inferred.first.external_id).service_instance)
      .to eq("omnifocus:default")
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:sync_collection_id)).not_to include(low.first.sync_collection_id)

    expect { described_class.run!(now: now + 1.day) }.not_to change(OutboxEntry, :count)
  end

  it "reports without changing local provenance or outbox rows in dry-run mode" do
    item = BaselineOmniFocusItem.create!(title: "Unidentified", external_id: "of-1")
    item.update_columns(source_service_name: nil, source_service_instance: nil, last_observed_at: nil)

    summary = described_class.run!(dry_run: true, now:)

    expect(summary).to include(dry_run: true)
    expect(OutboxEntry.count).to eq(0)
    expect(item.reload.source_service_name).to be_nil
    expect(item.last_observed_at).to be_nil
  end

  def collection_with(method, confidence, *classes)
    collection = SyncCollection.create!(title: "Release", mapping_method: method, mapping_confidence: confidence,
                                        mapping_last_observed_at: now)
    classes.map.with_index do |klass, index|
      klass.create!(title: "Release", external_id: "#{collection.id}-#{klass.name}-#{index}", sync_collection: collection,
                    options: options_for(klass))
    end
  end

  def options_for(klass)
    service_name = {
      "BaselineAsanaItem" => "Asana:work",
      "BaselineGithubItem" => "Github:repo",
      "BaselineGoogleTasksItem" => "Google Tasks",
      "BaselineOmniFocusItem" => "Omnifocus"
    }.fetch(klass.name)
    { service_name:, services: [], primary: "Asana", tags: [] }
  end

  def stub_item(name, provider)
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
end
