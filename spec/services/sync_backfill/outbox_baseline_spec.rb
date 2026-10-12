# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:backfilled_at) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:options) { { services: [], primary: "Asana", tags: [] } }

  before do
    stub_item("BackfillOmniFocusItem", "Omnifocus")
    stub_item("BackfillAsanaItem", "Asana")
    stub_item("BackfillGithubItem", "Github")
    stub_item("BackfillGoogleTasksItem", "Google Tasks")
  end

  it "seeds idempotent item baselines and only confident mappings for representative providers" do
    confident = SyncCollection.create!(title: "Release")
    tentative = SyncCollection.create!(title: "Private")
    omnifocus = create_legacy_item(BackfillOmniFocusItem, "Omnifocus", "of-1", tentative)
    asana = create_legacy_item(BackfillAsanaItem, "Asana:work", "asana-1", confident)
    github = create_legacy_item(BackfillGithubItem, "Github:repo", "gh-1", confident)
    google = create_legacy_item(BackfillGoogleTasksItem, "Google Tasks", "gt-1")

    travel_to(backfilled_at) { described_class.run!(backfilled_at:) }

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to contain_exactly("asana-1", "gh-1")
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:payload))
      .to all(include("mapping_confidence" => "inferred"))
    expect(omnifocus.reload.source_service_instance).to eq("default")
    expect(OutboxEntry.find_by(external_id: "of-1").service_instance).to eq("omnifocus:default")
    expect(OutboxEntry.find_by(external_id: "gt-1").service_instance).to eq("google_tasks:default")
    expect(OutboxEntry.find_by(external_id: "asana-1").payload.dig("provenance", "detected_by")).to eq("backfill")
    expect(confident.reload.mapping_confidence).to eq("medium")
    expect(tentative.reload.mapping_confidence).to eq("low")

    expect { described_class.run!(backfilled_at:) }.not_to change(OutboxEntry, :count)
    expect(asana.reload.first_observed_at).to be_present
    expect(github.reload.first_observed_at).to be_present
    expect(google.reload.first_observed_at).to be_present
  end

  it "reports without writing when dry-running" do
    collection = SyncCollection.create!(title: "Release")
    item = create_legacy_item(BackfillOmniFocusItem, "Omnifocus", "of-1", collection)
    create_legacy_item(BackfillAsanaItem, "Asana:work", "asana-1", collection)

    summary = described_class.run!(dry_run: true, backfilled_at:)

    expect(summary).to include("service_omnifocus" => 1, "medium_mappings" => 2)
    expect(OutboxEntry.count).to eq(0)
    expect(item.reload.source_service_name).to be_nil
    expect(collection.reload.mapping_method).to be_nil
  end

  def stub_item(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_singleton_method(:attribute_map) { {} }
      define_method(:external_data) { {} }
    end)
  end

  def create_legacy_item(klass, service_name, external_id, collection = nil)
    item = klass.create!(title: "Release", external_id:, sync_collection: collection,
                         options: options.merge(service_name:))
    item.update_columns(source_service_name: nil, source_service_instance: nil, source_service_type: nil,
                        source_external_id: nil, source_url: nil, source_updated_at: nil,
                        first_observed_at: nil, last_observed_at: nil, source_metadata: nil)
    item
  end
end
