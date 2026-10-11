# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  let(:item_classes) do
    {
      asana: item_class("BackfillAsanaItem", "Asana"),
      github: item_class("BackfillGithubItem", "Github"),
      omnifocus: item_class("BackfillOmnifocusItem", "Omnifocus"),
      google_tasks: item_class("BackfillGoogleTasksItem", "GoogleTasks")
    }
  end

  def item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_singleton_method(:attribute_map) { {} }

      define_method(:external_data) { {} }
    end)
  end

  def legacy_item(provider, external_id, collection:, service_name: provider)
    item = item_classes.fetch(provider).create!(
      title: "Release checklist",
      external_id:,
      sync_collection: collection,
      options: { service_name:, services: [], primary: "Omnifocus", tags: [] }
    )
    item.update_columns(
      source_service_name: nil,
      source_service_instance: nil,
      source_service_type: nil,
      source_external_id: nil,
      source_url: nil,
      source_updated_at: nil,
      first_observed_at: nil,
      last_observed_at: nil,
      source_metadata: nil,
      last_snapshot: nil
    )
    item
  end

  it "backfills representative item snapshots and only publishable mappings idempotently" do
    confirmed = SyncCollection.create!(
      title: "Release checklist",
      mapping_method: "source_sync_id",
      mapping_confidence: "high",
      mapping_established_at: Time.zone.parse("2026-10-01T10:00:00Z")
    )
    tentative = SyncCollection.create!(
      title: "Personal checklist",
      mapping_method: "manual_backfill",
      mapping_confidence: "low",
      mapping_established_at: Time.zone.parse("2026-10-01T10:00:00Z")
    )
    asana = legacy_item(:asana, "asana-1", collection: confirmed, service_name: "Asana:work")
    github = legacy_item(:github, "github-1", collection: confirmed)
    omnifocus = legacy_item(:omnifocus, "omnifocus-1", collection: tentative)
    google_tasks = legacy_item(:google_tasks, "google-tasks-1", collection: tentative)

    first_summary = described_class.run!

    expect(first_summary).to include(
      dry_run: false,
      items: include(enqueued: 4, by_service: include("asana" => 1, "github" => 1, "omnifocus" => 1, "google_tasks" => 1)),
      mappings: include(enqueued: 2, by_confidence: include("high" => 2), skipped: include(low_confidence: 2))
    )
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(2)
    expect(OutboxEntry.where(record_kind: %w[observation sync_run])).to be_empty
    expect(OutboxEntry.find_by(record_kind: "item", external_id: asana.external_id).payload).to include(
      "provenance" => include("detected_by" => "backfill", "backfilled_at" => be_present)
    )
    expect(OutboxEntry.find_by(record_kind: "item", external_id: omnifocus.external_id).service_instance).to eq("omnifocus:default")
    expect(OutboxEntry.find_by(record_kind: "item", external_id: google_tasks.external_id).service_instance).to eq("google_tasks:default")
    expect([asana, github, omnifocus, google_tasks].map(&:reload)).to all(have_attributes(last_snapshot: be_present))

    expect { described_class.run! }.not_to change(OutboxEntry, :count)
  end

  it "reports the same candidate and skipped counts without writing in dry-run mode" do
    collection = SyncCollection.create!(title: "Incomplete mapping")
    legacy_item(:asana, "asana-1", collection:)

    summary = described_class.run!(dry_run: true)

    expect(summary).to include(
      dry_run: true,
      items: include(enqueued: 1),
      mappings: include(enqueued: 0, skipped: include(incomplete_provenance: 1))
    )
    expect(OutboxEntry.all).to be_empty
  end
end
