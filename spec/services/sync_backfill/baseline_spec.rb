# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Baseline, :full_options do
  let(:observed_at) { Time.zone.parse("2026-10-10T10:00:00Z") }

  def item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_singleton_method(:attribute_map) { {} }
      define_method(:external_data) { {} }
    end)
  end

  def create_item(klass, service_name, external_id, collection)
    klass.create!(
      title: "Baseline #{external_id}",
      external_id:,
      sync_collection: collection,
      options: options.merge(service_name:)
    ).tap { |item| item.update_columns(last_observed_at: observed_at, first_observed_at: observed_at) }
  end

  it "seeds idempotent baseline snapshots and only publishable mappings" do
    asana_class = item_class("BaselineAsanaItem", "Asana")
    omnifocus_class = item_class("BaselineOmniFocusItem", "Omnifocus")
    github_class = item_class("BaselineGithubItem", "Github")
    google_tasks_class = item_class("BaselineGoogleTasksItem", "GoogleTasks")
    confirmed = SyncCollection.create!(
      title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high",
      mapping_metadata: {}, mapping_established_at: observed_at, mapping_last_observed_at: observed_at
    )
    inferred = SyncCollection.create!(
      title: "Inferred", mapping_method: "title_fallback", mapping_confidence: "medium",
      mapping_metadata: {}, mapping_established_at: observed_at, mapping_last_observed_at: observed_at
    )
    create_item(asana_class, "Asana:work", "asana-1", confirmed)
    omnifocus = create_item(omnifocus_class, "Omnifocus", "omnifocus-1", confirmed)
    create_item(github_class, "Github:repo", "github-1", inferred)
    create_item(google_tasks_class, "GoogleTasks", "google-tasks-1", inferred)

    first_summary = described_class.run!
    second_summary = described_class.run!

    expect(first_summary).to include(
      items: include("asana" => 1, "omnifocus" => 1, "github" => 1, "google_tasks" => 1),
      mappings: include("high" => 2, "medium" => 2)
    )
    expect(second_summary).to eq(first_summary)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:payload)).to all(include("mapping_confidence" => satisfy { |value| %w[confirmed inferred].include?(value) }))
    expect(OutboxEntry.find_by(record_kind: "item", external_id: "omnifocus-1").payload)
      .to include("provenance" => include("detected_by" => "backfill", "baseline" => true))
    expect(omnifocus.reload.last_snapshot).to be_present
    expect(OutboxEntry.find_by(record_kind: "item", external_id: "omnifocus-1").service_instance).to eq("omnifocus:default")
  end

  it "reports low-confidence mappings and incomplete items without writing in dry-run mode" do
    collection = SyncCollection.create!(
      title: "Needs review", mapping_method: "manual_backfill", mapping_confidence: "low",
      mapping_metadata: {}, mapping_established_at: observed_at, mapping_last_observed_at: observed_at
    )
    klass = item_class("BaselineLowConfidenceItem", "Asana")
    create_item(klass, "Asana", "asana-low", collection)
    klass.create!(title: "Incomplete", options: options.merge(service_name: "Asana"))

    summary = described_class.run!(dry_run: true)

    expect(summary).to include(
      dry_run: true,
      withheld_mappings: include("low" => 1),
      skipped: include("missing_external_id" => 1)
    )
    expect(OutboxEntry.count).to eq(0)
  end
end
