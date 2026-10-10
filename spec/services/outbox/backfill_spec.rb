# frozen_string_literal: true

require "rails_helper"
require "stringio"

RSpec.describe Outbox::Backfill do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-06T09:00:00Z") }
  let(:backfill_at) { Time.zone.parse("2026-10-06T11:00:00Z") }
  let(:output) { StringIO.new }
  let(:options) do
    { services: [], primary: "Omnifocus", tags: [] }
  end

  def create_item(item_class, service_name, attributes = {})
    travel_to(observed_at) do
      item_class.create!(attributes.merge(options: options.merge(service_name:)))
    end
  end

  def run_backfill(dry_run: false)
    travel_to(backfill_at) { described_class.run!(dry_run:, output:) }
  end

  let(:confirmed_collection) do
    SyncCollection.create!(title: "Buy milk", mapping_method: "source_sync_id", mapping_confidence: "high",
                           mapping_last_observed_at: observed_at)
  end
  let(:inferred_collection) do
    SyncCollection.create!(title: "Fix leak", mapping_method: "title_fallback", mapping_confidence: "medium",
                           mapping_last_observed_at: observed_at)
  end
  let(:tentative_collection) do
    SyncCollection.create!(title: "Maybe linked", mapping_method: "manual_backfill", mapping_confidence: "low",
                           mapping_last_observed_at: observed_at)
  end
  # One representative record per service named in the acceptance criteria:
  # OmniFocus (primary, single instance), Asana (named work instance),
  # GitHub (repository instance), and Google Tasks (single instance).
  let!(:omnifocus_task) do
    create_item(Omnifocus::Task, "Omnifocus",
                title: "Buy milk", external_id: "of-77", due_at: Time.zone.parse("2026-10-07T17:00:00Z"),
                notes: "asana_work_id: 1201\n2% and eggs", sync_collection: confirmed_collection)
  end
  let!(:asana_task) do
    create_item(Asana::Task, "Asana:work",
                title: "Buy milk", external_id: "1201", notes: "omnifocus_id: of-77",
                url: "https://app.asana.com/0/1/1201", last_modified: Time.zone.parse("2026-10-06T08:00:00Z"),
                sync_collection: confirmed_collection)
  end
  let!(:github_issue) do
    create_item(Github::Issue, "Github:repo-1",
                title: "Fix leak", external_id: "42", status: "open",
                url: "https://github.com/viamin/task_bridge/issues/42", sync_collection: inferred_collection)
  end
  let!(:google_task) do
    create_item(GoogleTasks::Task, "GoogleTasks",
                title: "Buy oat milk", external_id: "gt-9", completed: true,
                completed_at: Time.zone.parse("2026-10-05T09:00:00Z"), sync_collection: tentative_collection)
  end

  describe "baseline item snapshots" do
    it "publishes one marked baseline row per existing item for each service" do
      summary = run_backfill

      expect(summary[:status]).to eq("backfilled")
      expect(summary[:items]).to eq(4)
      expect(summary[:item_rows_written]).to eq(4)
      expect(summary[:items_by_service]).to eq("asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1)

      rows = OutboxEntry.where(record_kind: "item").index_by(&:external_id)
      expect(rows.keys).to contain_exactly("of-77", "1201", "42", "gt-9")
      expect(rows.values.map(&:service_instance))
        .to contain_exactly("omnifocus:default", "asana:work", "github:repo-1", "google_tasks:default")

      asana_row = rows["1201"]
      expect(asana_row.observed_at).to eq(observed_at)
      expect(asana_row.source_updated_at).to eq(Time.zone.parse("2026-10-06T08:00:00Z"))
      expect(asana_row.idempotency_key).to eq("tb:v1:item:asana:work:1201:snapshot:2026-10-06T09:00:00.000000Z")
      expect(asana_row.payload).to include(
        "item_key" => "asana_work:1201",
        "entity_type" => "task",
        "observed_at" => "2026-10-06T09:00:00.000000Z",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false
      )
      expect(asana_row.payload["source"]).to include(
        "service_type" => "asana",
        "service_instance" => "asana:work",
        "external_id" => "1201",
        "source_url" => "https://app.asana.com/0/1/1201"
      )
      expect(asana_row.payload["provenance"]).to eq(
        "detected_by" => "backfill",
        "backfilled_at" => "2026-10-06T11:00:00.000000Z",
        "first_observed_at" => "2026-10-06T09:00:00.000000Z"
      )
      expect(asana_row.payload["sync_collection_id"]).to be_nil
      expect(asana_row.payload).not_to include("notes_preview")

      expect(rows["gt-9"].payload).to include("status" => "completed",
                                              "completed_at" => "2026-10-05T09:00:00.000000Z")
      expect(rows["42"].payload.dig("source", "source_url")).to eq("https://github.com/viamin/task_bridge/issues/42")
      expect(rows["of-77"].payload["due_at"]).to eq("2026-10-07T17:00:00.000000Z")
      # Note text never leaves as content, only as a keyed digest.
      expect(rows["of-77"].payload["notes_digest"]).to be_a(String)
      expect(rows["of-77"].payload.to_json).not_to include("2% and eggs")

      expect(output.string).to include("Outbox backfill: wrote 4 item rows and 3 mapping rows")
      expect(output.string).to include("asana=1")
    end

    it "invents no observations or sync-run summaries" do
      run_backfill

      expect(OutboxEntry.where(record_kind: %w[observation sync_run])).to be_empty
    end
  end

  describe "mapping rows" do
    it "enqueues confirmed and inferred memberships and withholds tentative ones" do
      summary = run_backfill

      expect(summary[:mappings]).to eq(3)
      expect(summary[:mapping_rows_written]).to eq(3)
      expect(summary[:withheld_mappings]).to eq(1)
      expect(summary[:mappings_by_confidence]).to eq("confirmed" => 2, "inferred" => 1, "tentative" => 1)

      rows = OutboxEntry.where(record_kind: "mapping")
      expect(rows.map(&:external_id)).to contain_exactly("1201", "of-77", "42")
      expect(rows.map(&:sync_collection_id)).not_to include(tentative_collection.id)

      inferred = rows.find { |row| row.external_id == "42" }
      expect(inferred.payload).to include(
        "mapping_type" => "representation_membership",
        "mapping_confidence" => "inferred",
        "mapping_source" => "title_match"
      )
      expect(inferred.payload["provenance"]).to include(
        "detected_by" => "backfill",
        "backfilled_at" => "2026-10-06T11:00:00.000000Z",
        "method" => "title_fallback",
        "confidence" => "medium"
      )
      expect(inferred.idempotency_key).to eq(
        "tb:v1:map:sync_collection:#{inferred_collection.id}:membership:github:repo-1:42:2026-10-06T09:00:00.000000Z"
      )

      confirmed = rows.find { |row| row.external_id == "1201" }
      expect(confirmed.payload).to include("mapping_confidence" => "confirmed", "mapping_source" => "sync_id_note")
    end

    it "keeps tentative memberships reviewable through the summary counts" do
      summary = run_backfill

      expect(OutboxEntry.where(record_kind: "mapping", sync_collection_id: tentative_collection.id)).to be_empty
      expect(summary[:mappings_by_confidence]["tentative"]).to eq(1)
      expect(summary[:withheld_mappings]).to eq(1)
    end
  end

  describe "idempotency" do
    it "writes nothing new on a rerun and leaves stored payloads untouched" do
      run_backfill
      rows_before = OutboxEntry.all.map { |row| [row.idempotency_key, row.payload] }
      items_before = Base::SyncItem.pluck(:id, :last_observed_at, :updated_at, :last_snapshot)

      summary = travel_to(backfill_at + 1.hour) { described_class.run!(output:) }

      expect(summary).to include(status: "backfilled", item_rows_written: 0, mapping_rows_written: 0)
      expect(OutboxEntry.count).to eq(rows_before.length)
      expect(OutboxEntry.all.map { |row| [row.idempotency_key, row.payload] }).to eq(rows_before)
      expect(Base::SyncItem.pluck(:id, :last_observed_at, :updated_at, :last_snapshot)).to eq(items_before)
    end
  end

  describe "diff baseline" do
    it "advances the live baseline so an unchanged refresh emits no observations" do
      run_backfill

      # A freshly loaded record, exactly like the next sync run would hold:
      # its snapshot must match the stored baseline the backfill wrote.
      item = Omnifocus::Task.find(omnifocus_task.id)
      expect(item.last_snapshot).to include(
        "item_key" => "omnifocus:of-77",
        "title" => "Buy milk",
        "observed_at" => "2026-10-06T09:00:00.000000Z"
      )

      expect do
        Outbox::ObservationEmitter.emit_for_item(item, previous_snapshot: item.last_snapshot)
      end.not_to(change { OutboxEntry.where(record_kind: "observation").count })
    end
  end

  describe "identity completion" do
    it "runs the source provenance backfill first so legacy rows keep inferred instances" do
      asana_task.update_columns(
        source_service_name: nil, source_service_instance: nil, source_service_type: nil,
        source_external_id: nil, source_url: nil, source_updated_at: nil,
        first_observed_at: nil, last_observed_at: nil
      )

      run_backfill

      row = OutboxEntry.find_by(record_kind: "item", external_id: "1201")
      expect(row.service_instance).to eq("asana:work")
      expect(row.observed_at).to eq(observed_at)
      expect(row.idempotency_key).to eq("tb:v1:item:asana:work:1201:snapshot:2026-10-06T09:00:00.000000Z")
    end
  end

  describe "dry run" do
    it "writes nothing and summarizes counts by service and confidence" do
      summary = run_backfill(dry_run: true)

      expect(summary[:status]).to eq("dry_run")
      expect(summary[:items]).to eq(4)
      expect(summary[:item_rows_written]).to eq(0)
      expect(summary[:items_by_service]).to eq("asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1)
      expect(summary[:mappings]).to eq(3)
      expect(summary[:withheld_mappings]).to eq(1)
      expect(summary[:mappings_by_confidence]).to eq("confirmed" => 2, "inferred" => 1, "tentative" => 1)

      expect(OutboxEntry.count).to eq(0)
      expect(Base::SyncItem.where(last_snapshot: nil).count).to eq(4)

      expect(output.string).to include("Outbox backfill dry run: would enqueue 4 item snapshots and 3 mapping rows")
      expect(output.string).to include("item snapshots by service: asana=1, github=1, google_tasks=1, omnifocus=1")
      expect(output.string).to include("mapping memberships by confidence: confirmed=2, inferred=1, tentative=1")
      expect(output.string).to include("1 withheld from publication")
      expect(output.string).to include("skipped: 0 items and 0 memberships")
    end

    it "flags records the source provenance backfill would still complete" do
      asana_task.update_columns(last_observed_at: nil)

      run_backfill(dry_run: true)

      expect(output.string).to include("note: some records have not completed the source provenance backfill")
    end
  end

  describe "incomplete records" do
    it "counts items and memberships without an external id as skipped" do
      create_item(Omnifocus::Task, "Omnifocus", title: "No external id")
      create_item(Github::Issue, "Github:repo-1", title: "No id either", sync_collection: tentative_collection)

      summary = run_backfill(dry_run: true)

      expect(summary[:skipped_items]).to eq(2)
      expect(summary[:skipped_memberships]).to eq(1)
      expect(summary[:items]).to eq(4)
    end
  end
end
