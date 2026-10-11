# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Observations, :full_options do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-11T10:00:00Z") }

  def item_class(name, provider_name)
    stub_const(name, Class.new(Base::SyncItem) do
      define_singleton_method(:attribute_map) { {} }
      define_method(:provider) { provider_name }
      define_method(:external_data) { {} }
    end)
  end

  def create_item(klass, service_name:, external_id:, collection:, notes: nil)
    klass.create!(
      title: "Release checklist",
      external_id:,
      notes:,
      sync_collection: collection,
      last_modified: observed_at - 1.day,
      options: options.merge(service_name:)
    )
  end

  it "seeds idempotent baseline snapshots and only publishable mappings" do
    asana = item_class("BackfillAsanaItem", "Asana")
    omnifocus = item_class("BackfillOmniFocusItem", "Omnifocus")
    github = item_class("BackfillGithubItem", "Github")
    google_tasks = item_class("BackfillGoogleTasksItem", "GoogleTasks")
    confirmed = SyncCollection.create!(title: "Confirmed")
    inferred = SyncCollection.create!(title: "Inferred")
    low_confidence = SyncCollection.create!(title: "Needs review")
    create_item(asana, service_name: "Asana:work", external_id: "asana-1", collection: confirmed,
                       notes: "omnifocus_id: of-1")
    create_item(omnifocus, service_name: "Omnifocus", external_id: "of-1", collection: confirmed)
    create_item(github, service_name: "Github:repo-1", external_id: "issue-1", collection: inferred)
    create_item(google_tasks, service_name: "GoogleTasks", external_id: "task-1", collection: inferred)
    create_item(asana, service_name: "Asana:work", external_id: "asana-unpaired", collection: low_confidence)

    summary = travel_to(observed_at) { described_class.run! }

    expect(summary[:items]).to include("asana" => 2, "omnifocus" => 1, "github" => 1, "google_tasks" => 1)
    expect(summary[:mappings]).to include("high" => 1, "medium" => 1, "low" => 1)
    expect(summary[:skipped]).to include(mappings_low_confidence: 1)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(5)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).not_to include("asana-unpaired")
    expect(OutboxEntry.where(record_kind: "item").first.payload).to include(
      "provenance" => include("detected_by" => "backfill", "backfilled_at" => observed_at.iso8601(6))
    )
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:payload)).to include(
      include("mapping_confidence" => "confirmed"), include("mapping_confidence" => "inferred")
    )
    expect(Base::SyncItem.find_by!(external_id: "of-1").source_service_instance).to eq("default")
    expect(OutboxEntry.find_by!(external_id: "of-1", record_kind: "item").service_instance).to eq("omnifocus:default")

    expect { described_class.run! }.not_to change(OutboxEntry, :count)
  end

  it "reports candidate work without writing in dry-run mode" do
    asana = item_class("DryRunAsanaItem", "Asana")
    collection = SyncCollection.create!(title: "Needs review")
    create_item(asana, service_name: "Asana", external_id: "asana-1", collection:)
    item = Base::SyncItem.find_by!(external_id: "asana-1")
    attributes_before = item.attributes.slice("last_observed_at", "last_snapshot", "source_service_name")

    summary = described_class.run!(dry_run: true)

    expect(summary[:items]).to include("asana" => 1)
    expect(summary[:mappings]).to include("low" => 1)
    expect(summary[:skipped]).to include(mappings_low_confidence: 1)
    expect(OutboxEntry.count).to eq(0)
    expect(Base::SyncItem.find_by!(external_id: "asana-1").attributes.slice(*attributes_before.keys)).to eq(attributes_before)
  end
end
