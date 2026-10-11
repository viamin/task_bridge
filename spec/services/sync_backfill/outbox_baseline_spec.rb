# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:item_options) { { service_name: "Asana", services: [], primary: "PrimaryService", tags: [] } }
  let(:item_classes) do
    {
      "Asana" => backfill_item_class("BackfillAsanaItem", "Asana"),
      "Omnifocus" => backfill_item_class("BackfillOmniFocusItem", "Omnifocus"),
      "Github" => backfill_item_class("BackfillGithubItem", "Github"),
      "Google Tasks" => backfill_item_class("BackfillGoogleTasksItem", "Google Tasks")
    }
  end

  before { item_classes }

  it "seeds deterministic item baselines for representative services without observations" do
    items = item_classes.map do |service, item_class|
      item_class.create!(title: "#{service} task", external_id: service.parameterize,
                         options: item_options.merge(service_name: service), updated_at: observed_at)
    end

    first_summary = described_class.run!
    described_class.run!

    expect(first_summary).to include(items_asana: 1, items_omnifocus: 1, items_github: 1, items_google_tasks: 1)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.pluck(:service_instance)).to contain_exactly(
      "asana:default", "omnifocus:default", "github:default", "google_tasks:default"
    )

    row = OutboxEntry.find_by(external_id: "asana")
    expect(row.payload).to include(
      "contract_version" => 1,
      "provenance" => include("detected_by" => "backfill", "baseline" => true)
    )
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)
  end

  it "withholds low-confidence mappings and reports them in a dry run" do
    collection = SyncCollection.create!(title: "Uncertain", mapping_method: "manual_backfill", mapping_confidence: "low")
    item = item_classes.fetch("Asana").create!(
      title: "Uncertain", external_id: "asana-1", sync_collection: collection, options: item_options
    )

    summary = described_class.run!(dry_run: true)

    expect(summary).to include(mappings_low: 1, mappings_withheld_low_confidence: 1)
    expect(OutboxEntry.count).to be_zero
    expect(item.reload.last_snapshot).to be_nil
  end

  it "publishes high and medium-confidence memberships with contract confidence" do
    high = collection_with_member("high", "source_sync_id", "asana-high")
    medium = collection_with_member("medium", "title_fallback", "github-medium")

    described_class.run!

    expect(OutboxEntry.where(record_kind: "mapping").order(:external_id).pluck(:payload)).to contain_exactly(
      include("mapping_confidence" => "confirmed", "mapping_source" => "sync_id_note"),
      include("mapping_confidence" => "inferred", "mapping_source" => "title_match")
    )
    expect(high.mapping_confidence).to eq("high")
    expect(medium.mapping_confidence).to eq("medium")
  end

  private

  def backfill_item_class(constant_name, provider_name)
    stub_const(constant_name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider_name }

      define_singleton_method(:attribute_map) { {} }
      define_method(:external_data) { {} }
    end)
  end

  def collection_with_member(confidence, method, external_id)
    collection = SyncCollection.create!(title: external_id, mapping_method: method, mapping_confidence: confidence)
    item_class = external_id.start_with?("github") ? item_classes.fetch("Github") : item_classes.fetch("Asana")
    item_class.create!(title: external_id, external_id:, sync_collection: collection, options: item_options)
    collection
  end
end
