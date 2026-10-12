# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::SourceProvenance do
  include ActiveSupport::Testing::TimeHelpers

  let(:item_classes) do
    {
      omnifocus: backfill_item_class("BackfillOmniFocusItem", "Omnifocus"),
      asana: backfill_item_class("BackfillAsanaItem", "Asana"),
      github: backfill_item_class("BackfillGithubItem", "Github"),
      google_tasks: backfill_item_class("BackfillGoogleTasksItem", "GoogleTasks")
    }
  end

  def backfill_item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_singleton_method(:attribute_map) { {} }
      define_method(:external_data) { {} }
    end)
  end

  def create_item(item_class, external_id, collection)
    item_class.create!(
      title: "Release checklist",
      external_id:,
      sync_collection: collection,
      options: { service_name: item_class.new.provider, services: [], primary: "Asana", tags: [] }
    )
  end

  it "seeds idempotent baseline snapshots for OmniFocus, Asana, GitHub, and Google Tasks" do
    collection = SyncCollection.create!(title: "Release checklist", mapping_method: "source_sync_id", mapping_confidence: "high")
    items = item_classes.to_h { |service, item_class| [service, create_item(item_class, "#{service}-1", collection)] }

    travel_to(Time.zone.parse("2026-10-05T10:00:00Z")) do
      first_summary = described_class.run!
      second_summary = described_class.run!

      expect(first_summary[:items][:by_service]).to include(
        "omnifocus" => 1, "asana" => 1, "github" => 1, "google_tasks" => 1
      )
      expect(second_summary[:items][:enqueued]).to eq(4)
    end

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty

    items.each_value do |item|
      row = OutboxEntry.find_by!(record_kind: "item", external_id: item.external_id)
      expect(row.payload.dig("provenance", "detected_by")).to eq("backfill")
      expect(row.payload.dig("provenance", "backfilled_at")).to be_present
      expect(item.reload.last_snapshot).to eq(row.payload)
    end
    expect(OutboxEntry.find_by!(record_kind: "item", external_id: "omnifocus-1").service_instance).to eq("omnifocus:default")
  end

  it "withholds low-confidence mappings and reports them during a dry run without writes" do
    collection = SyncCollection.create!(title: "Ambiguous", mapping_method: "title_fallback", mapping_confidence: "low")
    create_item(item_classes.fetch(:asana), "asana-ambiguous", collection)
    incomplete = item_classes.fetch(:github).create!(title: "Incomplete", sync_collection: collection)
    incomplete_last_observed_at = incomplete.last_observed_at

    summary = described_class.run!(dry_run: true)

    expect(summary).to include(dry_run: true, observations: 0, sync_runs: 0)
    expect(summary[:items][:skipped_incomplete]).to eq(1)
    expect(summary[:mappings][:withheld_low_confidence]).to eq(2)
    expect(summary[:mappings][:by_confidence]).to include("low" => 2)
    expect(OutboxEntry.all).to be_empty
    expect(incomplete.reload.last_observed_at).to eq(incomplete_last_observed_at)
  end
end
