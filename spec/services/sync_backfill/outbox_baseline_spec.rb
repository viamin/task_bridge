# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline, :full_options do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-01T12:00:00Z") }
  let(:collection) do
    SyncCollection.create!(
      title: "Release checklist", mapping_method: "source_sync_id", mapping_confidence: "high",
      mapping_established_at: observed_at
    )
  end

  def create_item(item_class, external_id)
    attributes = {
      title: "Release checklist", external_id:, sync_collection: collection,
      options: { services: [], primary: "PrimaryService", tags: [] }
    }
    attributes[:github_issue] = { "repository_url" => "https://api.github.com/repos/example/tasks" } if item_class == Github::Issue
    item_class.create!(attributes).tap do |item|
      item.update_columns(first_observed_at: observed_at, last_observed_at: observed_at)
    end
  end

  it "seeds idempotent baseline snapshots and mappings for supported services" do
    create_item(Omnifocus::Task, "of-1")
    create_item(Asana::Task, "asana-1")
    create_item(Github::Issue, "gh-1")
    create_item(GoogleTasks::Task, "gt-1")

    first_summary = described_class.run!

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "item").pluck(:service_instance))
      .to contain_exactly("omnifocus:default", "asana:default", "github:default", "google_tasks:default")
    expect(OutboxEntry.where(record_kind: "item").map { |row| row.payload.dig("provenance", "detected_by") })
      .to all(eq("backfill"))

    expect { described_class.run! }.not_to change(OutboxEntry, :count)
    expect(first_summary.values.sum).to eq(8)
  end

  it "withholds low-confidence mappings and reports them in a dry run" do
    collection.update!(mapping_method: "title_fallback", mapping_confidence: "low")
    create_item(Omnifocus::Task, "of-1")

    summary = described_class.run!(dry_run: true)

    expect(OutboxEntry.count).to eq(0)
    expect(summary).to include([:items, "omnifocus", nil] => 1,
                               [:mappings_withheld_low_confidence, "omnifocus", "low"] => 1)
  end

  it "publishes medium-confidence mappings as inferred" do
    collection.update!(mapping_method: "title_fallback", mapping_confidence: "medium")
    create_item(Asana::Task, "asana-1")

    described_class.run!

    expect(OutboxEntry.find_by(record_kind: "mapping").payload["mapping_confidence"]).to eq("inferred")
  end
end
