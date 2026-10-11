# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::BaselineOutbox do
  include ActiveSupport::Testing::TimeHelpers

  let(:backfill_at) { Time.zone.parse("2026-10-11T09:00:00Z") }
  let(:base_options) { { services: [], primary: "Omnifocus", tags: [] } }
  let(:high_collection) { SyncCollection.create!(title: "Buy milk") }
  let(:low_collection) { SyncCollection.create!(title: "Review someday") }

  # Representative records for the four core services: OmniFocus (primary,
  # single instance), Asana (configured instance), GitHub, Google Tasks.
  let(:omnifocus_task) do
    Omnifocus::Task.create!(
      title: "Buy milk", external_id: "of-1", notes: "asana_work_id: asana-1",
      sync_collection: high_collection, options: base_options
    )
  end
  let(:asana_task) do
    Asana::Task.create!(
      title: "Buy milk", external_id: "asana-1", notes: "omnifocus_id: of-1",
      sync_collection: high_collection, options: base_options.merge(service_name: "Asana:work")
    )
  end
  let(:github_issue) do
    Github::Issue.create!(title: "Fix the widget", external_id: "issue-9",
                          sync_collection: low_collection, options: base_options)
  end
  let(:google_tasks_task) do
    GoogleTasks::Task.create!(title: "Read the manual", external_id: "gt-1",
                              sync_collection: low_collection, options: base_options)
  end

  def strip_provenance!
    [omnifocus_task, asana_task, github_issue, google_tasks_task].each do |item|
      item.update_columns(
        source_service_name: nil, source_service_instance: nil, source_service_type: nil,
        source_external_id: nil, source_url: nil, source_created_at: nil, source_updated_at: nil,
        first_observed_at: nil, last_observed_at: nil, source_metadata: nil
      )
    end
    [high_collection, low_collection].each do |collection|
      collection.update_columns(
        mapping_method: nil, mapping_confidence: nil, mapping_metadata: nil,
        mapping_established_at: nil, mapping_last_observed_at: nil
      )
    end
  end

  def run_backfill(at: backfill_at, **)
    travel_to(at) { described_class.run!(**) }
  end

  before do
    omnifocus_task
    asana_task
    github_issue
    google_tasks_task
    strip_provenance!
  end

  describe "write mode" do
    it "enqueues one baseline item row per existing item across services" do
      summary = run_backfill

      rows = OutboxEntry.where(record_kind: "item").index_by(&:external_id)
      expect(rows.keys).to contain_exactly("of-1", "asana-1", "issue-9", "gt-1")
      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
      expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty

      expect(rows.fetch("of-1")).to have_attributes(service_type: "omnifocus", service_instance: "omnifocus:default")
      expect(rows.fetch("asana-1")).to have_attributes(service_type: "asana", service_instance: "asana:work")
      expect(rows.fetch("issue-9")).to have_attributes(service_type: "github", service_instance: "github:default")
      expect(rows.fetch("gt-1")).to have_attributes(service_type: "google_tasks", service_instance: "google_tasks:default")

      observed_at = asana_task.reload.last_observed_at.utc.iso8601(6)
      expect(rows.fetch("asana-1").observed_at).to eq(asana_task.last_observed_at)
      expect(rows.fetch("asana-1").idempotency_key)
        .to eq("tb:v1:item:asana:work:asana-1:snapshot:#{observed_at}")
      expect(rows.fetch("asana-1").payload).to include(
        "contract_version" => 1,
        "entity_type" => "task",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false
      )
      expect(rows.fetch("asana-1").payload["source"]).to include(
        "service_type" => "asana", "service_instance" => "asana:work", "external_id" => "asana-1"
      )
      expect(rows.fetch("asana-1").payload["item_key"]).to eq(asana_task.item_key)
      expect(rows.fetch("asana-1").payload["provenance"]).to eq(
        "detected_by" => "backfill",
        "backfilled_at" => backfill_at.utc.iso8601(6)
      )

      expect(summary).to include(
        dry_run: false,
        items_by_service: { "asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1 },
        items_skipped: {},
        item_rows_created: 4
      )
    end

    it "stamps the diff baseline on every backfilled item" do
      run_backfill

      [omnifocus_task, asana_task, github_issue, google_tasks_task].each do |item|
        expect(item.reload.last_snapshot).to include("item_key" => item.item_key, "is_deleted" => false)
      end
    end

    it "publishes mapping rows only for confirmed and inferred memberships" do
      run_backfill

      mapping_rows = OutboxEntry.where(record_kind: "mapping")
      expect(mapping_rows.map(&:external_id)).to contain_exactly("of-1", "asana-1")

      row = mapping_rows.find { |entry| entry.external_id == "of-1" }
      expect(row.observed_at).to eq(high_collection.reload.mapping_established_at)
      expect(row.sync_collection_id).to eq(high_collection.id)
      expect(row.payload).to include("mapping_confidence" => "confirmed", "mapping_source" => "sync_id_note")
      expect(row.payload["provenance"]).to include(
        "detected_by" => "backfill",
        "backfilled_at" => backfill_at.utc.iso8601(6)
      )
    end

    it "withholds low-confidence memberships and reports them for review" do
      summary = run_backfill

      expect(OutboxEntry.where(record_kind: "mapping").map(&:sync_collection_id).uniq).to eq([high_collection.id])
      expect(summary[:mappings_by_confidence]).to eq("confirmed" => 2)
      expect(summary[:mappings_withheld]).to eq(2)
      expect(summary[:withheld_collections]).to contain_exactly(
        hash_including(id: low_collection.id, title: "Review someday", confidence: "tentative", members: 2)
      )
      expect(summary[:mapping_rows_created]).to eq(2)
    end

    it "runs the provenance backfill first so identity fields are populated" do
      run_backfill

      expect(asana_task.reload.source_service_name).to eq("Asana:work")
      expect(asana_task.source_service_instance).to eq("work")
      expect(asana_task.source_external_id).to eq("asana-1")
      expect(asana_task.first_observed_at).to be_present
      expect(high_collection.reload.mapping_method).to eq("source_sync_id")
      expect(low_collection.reload.mapping_confidence).to eq("low")
    end
  end

  describe "idempotency" do
    it "does not duplicate rows or mutate stored payloads on reruns" do
      run_backfill
      run_counts = OutboxEntry.count

      summary = run_backfill(at: backfill_at + 2.hours)

      expect(OutboxEntry.count).to eq(run_counts)
      expect(summary[:item_rows_created]).to eq(0)
      expect(summary[:mapping_rows_created]).to eq(0)
      stored = OutboxEntry.find_by(record_kind: "item", external_id: "of-1")
      expect(stored.payload["provenance"]["backfilled_at"]).to eq(backfill_at.utc.iso8601(6))
      expect(omnifocus_task.reload.last_observed_at).to eq(stored.observed_at)
    end

    it "keeps the summary stable across reruns" do
      first = run_backfill
      second = run_backfill(at: backfill_at + 1.hour)

      expect(second[:items_by_service]).to eq(first[:items_by_service])
      expect(second[:mappings_by_confidence]).to eq(first[:mappings_by_confidence])
      expect(second[:mappings_withheld]).to eq(first[:mappings_withheld])
    end
  end

  describe "skipped and incomplete records" do
    it "skips items without an external id and counts them by service" do
      Omnifocus::Task.create!(title: "No id", options: base_options)

      summary = run_backfill

      expect(summary[:items_skipped]).to eq("omnifocus" => 1)
      expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    end

    it "counts collection members without an external id as skipped" do
      Omnifocus::Task.create!(title: "No id", sync_collection: low_collection, options: base_options)

      summary = run_backfill

      expect(summary[:mapping_members_skipped]).to eq(1)
      expect(summary[:mappings_withheld]).to eq(2)
    end
  end

  describe "dry run" do
    it "writes nothing and summarizes what the write run would enqueue" do
      summary = run_backfill(dry_run: true)

      expect(OutboxEntry.count).to eq(0)
      expect(asana_task.reload.source_service_name).to be_nil
      expect(asana_task.last_observed_at).to be_nil
      expect(asana_task.last_snapshot).to be_nil
      expect(high_collection.reload.mapping_method).to be_nil

      expect(summary).to include(
        dry_run: true,
        items_by_service: { "asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1 },
        items_skipped: {},
        mappings_by_confidence: { "confirmed" => 2 },
        mappings_withheld: 2,
        item_rows_created: 0,
        mapping_rows_created: 0
      )
      expect(summary[:withheld_collections]).to contain_exactly(hash_including(id: low_collection.id, members: 2))
    end
  end

  describe "integration with the live observation pipeline" do
    let(:item_class) do
      stub_const("BaselineOutboxSpecItem", Class.new(Base::SyncItem) do
        def self.attribute_map
          {}
        end

        def provider
          "BaselineSpecService"
        end

        def external_data
          @sync_item
        end
      end)
    end
    # Created without explicit options so the backfill's database-loaded
    # instance and the in-memory refresh resolve the same global tag set;
    # tags are part of the diffed snapshot.
    let(:item) { item_class.create!(title: "Buy milk", external_id: "base-1") }

    before do
      item_class
      item
    end

    def refresh_with(external_attributes, at:)
      travel_to(at) do
        item.instance_variable_set(:@sync_item, { "id" => "base-1" }.merge(external_attributes))
        item.refresh_from_external!
      end
    end

    it "treats the backfilled snapshot as the diff baseline, not a new discovery" do
      run_backfill
      item.reload
      expect(OutboxEntry.where(record_kind: "observation")).to be_empty

      refresh_with({ "title" => "Buy milk", "completed" => false }, at: backfill_at + 1.hour)
      expect(OutboxEntry.where(record_kind: "observation")).to be_empty

      refresh_with({ "title" => "Buy oat milk", "completed" => false }, at: backfill_at + 2.hours)
      changes = OutboxEntry.where(record_kind: "observation").map { |row| row.payload.dig("change", "field") }
      expect(changes).to eq(["title"])
    end
  end
end
