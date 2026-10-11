# frozen_string_literal: true

require "rails_helper"
require "stringio"

RSpec.describe SyncBackfill::OutboxBaseline, :full_options do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:output) { StringIO.new }
  let(:classes) do
    {
      omnifocus: backfill_item_class("BackfillOmnifocusItem", "Omnifocus"),
      asana: backfill_item_class("BackfillAsanaItem", "Asana"),
      github: backfill_item_class("BackfillGithubItem", "Github"),
      google_tasks: backfill_item_class("BackfillGoogleTasksItem", "GoogleTasks")
    }
  end

  before { classes }

  it "backfills snapshots for supported sources, mappings, and a diff baseline idempotently" do
    high_confidence_collection = SyncCollection.create!(title: "Release")
    low_confidence_collection = SyncCollection.create!(title: "Uncertain")
    create_item(classes[:asana], "asana-1", high_confidence_collection, "github_id: github-1")
    create_item(classes[:github], "github-1", high_confidence_collection, "asana_id: asana-1")
    create_item(classes[:omnifocus], "omnifocus-1", low_confidence_collection)
    create_item(classes[:google_tasks], "google-1")
    incomplete = create_item(classes[:asana], nil)

    travel_to(observed_at) { described_class.run!(output:) }

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to contain_exactly("asana-1", "github-1")
    expect(OutboxEntry.find_by(external_id: "omnifocus-1", record_kind: "item").service_instance)
      .to eq("omnifocus:default")
    expect(classes[:asana].find_by!(external_id: "asana-1").last_snapshot).to be_present
    expect(incomplete.reload.last_snapshot).to be_nil
    expect(OutboxEntry.where(record_kind: "item").first.payload.dig("provenance", "detected_by")).to eq("backfill")
    expect(JSON.parse(output.string)).to include(
      "items_by_service" => include("asana" => 1, "github" => 1, "omnifocus" => 1, "google_tasks" => 1),
      "mappings_by_confidence" => include("high" => 2, "low" => 1),
      "skipped" => include("items.missing_external_id" => 1)
    )

    expect { described_class.run!(output:) }.not_to change(OutboxEntry, :count)
  end

  it "reports a dry run without mutating existing records" do
    item = create_item(classes[:asana], "asana-dry")

    expect do
      described_class.run!(dry_run: true, output:)
    end.not_to(change { [OutboxEntry.count, item.reload.last_snapshot, item.source_service_name] })

    expect(JSON.parse(output.string)).to include("items_by_service" => include("asana" => 1))
  end

  def backfill_item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      define_method(:external_data) { {} }

      define_singleton_method(:attribute_map) { {} }
    end)
  end

  def create_item(item_class, external_id, collection = nil, notes = nil)
    item_class.create!(external_id:, title: "Task #{external_id}", notes:, sync_collection: collection,
                       last_modified: observed_at)
  end
end
