# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Outbox do
  let(:observed_at) { Time.zone.parse("2026-10-06T12:00:00Z") }
  let(:item_classes) do
    {
      omnifocus: item_class("BackfillOmniFocusItem", "Omnifocus"),
      asana: item_class("BackfillAsanaItem", "Asana"),
      github: item_class("BackfillGithubItem", "Github"),
      google_tasks: item_class("BackfillGoogleTasksItem", "Google Tasks")
    }
  end

  before { item_classes }

  it "previews without writing, then idempotently emits baseline snapshots and confirmed mappings" do
    confirmed = SyncCollection.create!(title: "Pay bills", mapping_method: "source_sync_id", mapping_confidence: "high")
    tentative = SyncCollection.create!(title: "Review pull request", mapping_method: "manual_backfill", mapping_confidence: "low")
    omnifocus = create_item(:omnifocus, "of-1", confirmed)
    asana = create_item(:asana, "asana-1", confirmed, "Asana:work")
    github = create_item(:github, "gh-1", tentative, "Github:repo")
    google_tasks = create_item(:google_tasks, "gt-1", tentative)
    [omnifocus, asana, github, google_tasks].each { |item| item.update_columns(source_service_instance: nil) }

    preview = described_class.run!(dry_run: true)

    expect(preview).to include(
      dry_run: true,
      items_by_service: { "asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1 },
      mappings_by_confidence: { "high" => 2 },
      skipped: { "withheld_low_confidence_mapping" => 2 }
    )
    expect(OutboxEntry.count).to eq(0)
    expect(omnifocus.reload.source_service_instance).to be_nil

    result = described_class.run!
    described_class.run!

    expect(result[:dry_run]).to be(false)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(2)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to contain_exactly("of-1", "asana-1")
    expect(OutboxEntry.find_by(record_kind: "item", external_id: "of-1").payload).to include(
      "provenance" => { "detected_by" => "backfill", "backfilled_at" => observed_at.iso8601(6) }
    )
    expect(omnifocus.reload.source_service_instance).to eq("default")
    expect(OutboxEntry.find_by(record_kind: "item", external_id: "of-1").service_instance).to eq("omnifocus:default")
  end

  private

  def item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_singleton_method(:attribute_map) { {} }
      define_method(:external_data) { {} }
    end)
  end

  def create_item(service, external_id, collection, service_name = nil)
    item = item_classes.fetch(service).create!(
      title: collection.title,
      external_id:,
      sync_collection: collection,
      options: { service_name:, services: [], primary: "PrimaryService", tags: [] }.compact
    )
    item.update_columns(first_observed_at: observed_at, last_observed_at: observed_at)
    item
  end
end
