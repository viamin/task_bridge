# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Baseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-11T09:00:00Z") }
  let(:item_options) { { services: [], primary: "Omnifocus", tags: [] } }
  let(:synced_collection) { SyncCollection.create!(title: "Buy milk") }

  # Representative legacy rows (pre-observation-pipeline data): real STI
  # classes for four providers, no provenance columns set, with sync IDs
  # living only in parsed notes.
  let!(:omnifocus_task) do
    Omnifocus::Task.create!(
      title: "Buy milk", external_id: "of-1", notes: "asana_work_id: asana-1",
      sync_collection: synced_collection, options: item_options
    )
  end
  let!(:asana_task) do
    Asana::Task.create!(
      title: "Buy milk", external_id: "asana-1", notes: "omnifocus_id: of-1",
      sync_collection: synced_collection, options: item_options
    )
  end
  let!(:github_issue) do
    Github::Issue.create!(
      title: "Buy milk", external_id: "gh-1", notes: "omnifocus_id: of-1",
      sync_collection: synced_collection, options: item_options
    )
  end
  let!(:google_task) do
    GoogleTasks::Task.create!(
      title: "Buy milk", external_id: "gt-1", notes: "omnifocus_id: of-1",
      sync_collection: synced_collection, options: item_options
    )
  end

  before do
    [omnifocus_task, asana_task, github_issue, google_task].each { |item| strip_provenance(item) }
  end

  around do |example|
    travel_to(observed_at) { example.run }
  end

  def strip_provenance(item)
    item.update_columns(
      source_service_name: nil,
      source_service_instance: nil,
      source_service_type: nil,
      source_external_id: nil,
      source_url: nil,
      source_created_at: nil,
      source_updated_at: nil,
      first_observed_at: nil,
      last_observed_at: nil,
      source_metadata: nil
    )
  end

  def run_backfill!
    described_class.run!
  end

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  it "backfills one baseline item snapshot per existing sync item" do
    summary = run_backfill!

    expect(summary[:items]).to eq(enqueued: 4, already_backfilled: 0, incomplete: 0)
    expect(summary[:items_by_service]).to eq("asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1)
    expect(item_rows.count).to eq(4)
  end

  it "marks baseline snapshots as backfill observations, not change events" do
    run_backfill!

    omnifocus_row = item_rows.find_by(external_id: "of-1")
    expect(omnifocus_row).to have_attributes(
      service_type: "omnifocus",
      service_instance: "omnifocus:default",
      event_type: nil,
      observed_at: observed_at
    )
    expect(omnifocus_row.idempotency_key).to eq(
      "tb:v1:item:omnifocus:default:of-1:snapshot:#{observed_at.utc.iso8601(6)}"
    )
    expect(omnifocus_row.payload).to include(
      "item_key" => "omnifocus:of-1",
      "entity_type" => "task",
      "title" => "Buy milk",
      "status" => "open",
      "is_deleted" => false,
      "source" => including(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-1",
        "source_url" => "omnifocus:///task/of-1"
      ),
      "provenance" => including(
        "detected_by" => "backfill",
        "backfilled_at" => observed_at.utc.iso8601(6),
        "first_observed_at" => observed_at.utc.iso8601(6)
      )
    )
    expect(omnifocus_row.payload).not_to include("event_type")
  end

  it "keeps instanced service identity stable across live and backfilled rows" do
    run_backfill!

    asana_row = item_rows.find_by(external_id: "asana-1")
    expect(asana_row.service_instance).to eq("asana:work")
    expect(asana_row.payload["item_key"]).to eq("asana_work:asana-1")
    expect(asana_row.payload["source"]["service_instance"]).to eq("asana:work")
  end

  it "emits no observation or sync_run rows from the backfill" do
    run_backfill!

    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
  end

  it "backfills mapping rows for existing memberships with deterministic keys" do
    summary = run_backfill!

    expect(summary[:mappings]).to include(memberships: 4, enqueued: 4, withheld_low_confidence: 0, incomplete: 0)
    expect(summary[:mappings_by_confidence]).to eq("confirmed" => 4)

    omnifocus_mapping = mapping_rows.find_by(external_id: "of-1")
    expect(omnifocus_mapping).to have_attributes(
      sync_collection_id: synced_collection.id,
      service_instance: "omnifocus:default",
      observed_at: observed_at
    )
    expect(omnifocus_mapping.idempotency_key).to eq(
      "tb:v1:map:sync_collection:#{synced_collection.id}:membership:omnifocus:default:of-1:#{observed_at.utc.iso8601(6)}"
    )
    expect(omnifocus_mapping.payload).to include(
      "mapping_confidence" => "confirmed",
      "mapping_source" => "sync_id_note",
      "sync_collection" => including("sync_collection_id" => synced_collection.id)
    )
  end

  it "is idempotent across repeated runs" do
    run_backfill!
    row_count = OutboxEntry.count

    summary = run_backfill!

    expect(summary[:items]).to eq(enqueued: 0, already_backfilled: 4, incomplete: 0)
    expect(summary[:mappings]).to include(enqueued: 0, already_backfilled: 4)
    expect(OutboxEntry.count).to eq(row_count)
  end

  it "counts memberships the live pipeline already published as backfilled" do
    Outbox::MappingEmitter.emit_for_members(synced_collection, members: [omnifocus_task.reload])

    summary = run_backfill!

    expect(summary[:mappings]).to include(enqueued: 3, already_backfilled: 1)
    expect(mapping_rows.where(external_id: "of-1").count).to eq(1)
  end

  it "reports items that cannot be identified as incomplete" do
    Github::Issue.create!(title: "No id", options: item_options)

    summary = run_backfill!

    expect(summary[:items]).to eq(enqueued: 4, already_backfilled: 0, incomplete: 1)
    expect(item_rows.where(external_id: nil)).to be_empty
  end

  describe "low-confidence mapping policy" do
    let(:title_matched_collection) { SyncCollection.create!(title: "Fix login") }
    let(:unmatched_collection) { SyncCollection.create!(title: "Orphan") }

    let!(:title_matched_items) do
      [Omnifocus::Task, GoogleTasks::Task].map do |item_class|
        item_class.create!(
          title: "Fix login", external_id: "#{item_class.name.demodulize.underscore}-9",
          sync_collection: title_matched_collection, options: item_options
        ).tap { |item| strip_provenance(item) }
      end
    end
    let!(:orphan_item) do
      GoogleTasks::Task.create!(
        title: "Orphan", external_id: "gt-9",
        sync_collection: unmatched_collection, options: item_options
      ).tap { |item| strip_provenance(item) }
    end

    it "publishes title-derived mappings as inferred but withholds low-confidence ones" do
      summary = run_backfill!

      expect(summary[:mappings]).to include(enqueued: 6, withheld_low_confidence: 1)
      expect(summary[:mappings_by_confidence]).to eq("confirmed" => 4, "inferred" => 2)

      title_rows = mapping_rows.where(sync_collection_id: title_matched_collection.id)
      expect(title_rows.map { |row| row.payload["mapping_confidence"] }).to eq(%w[inferred inferred])
      expect(title_rows.map { |row| row.payload["mapping_source"] }).to eq(%w[title_match title_match])

      expect(mapping_rows.where(sync_collection_id: unmatched_collection.id)).to be_empty
      expect(summary[:withheld_low_confidence_collections]).to contain_exactly(
        including(sync_collection_id: unmatched_collection.id, members: 1, mapping_method: "manual_backfill")
      )
    end

    it "omits the membership block from item snapshots of withheld collections" do
      run_backfill!

      orphan_row = item_rows.find_by(external_id: "gt-9")
      expect(orphan_row.payload).not_to include("sync_collection")

      matched_row = item_rows.find_by(external_id: "task-9")
      expect(matched_row.payload["sync_collection"]).to include(
        "sync_collection_id" => title_matched_collection.id,
        "mapping_confidence" => "inferred",
        "mapping_source" => "title_match"
      )
    end
  end

  describe "dry run" do
    it "summarizes without writing outbox rows or provenance" do
      summary = described_class.run!(dry_run: true)

      expect(summary[:dry_run]).to be(true)
      expect(summary[:items]).to eq(enqueued: 4, already_backfilled: 0, incomplete: 0)
      expect(summary[:mappings]).to include(enqueued: 4, already_backfilled: 0)
      expect(OutboxEntry.count).to eq(0)
      expect(omnifocus_task.reload.last_observed_at).to be_nil
      expect(synced_collection.reload.mapping_method).to be_nil
    end
  end
end
