# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:backfilled_at) { Time.zone.parse("2026-10-10T12:00:00Z") }
  let(:item_observed_at) { Time.zone.parse("2026-10-10T09:00:00Z") }
  let(:mapping_observed_at) { Time.zone.parse("2026-10-10T10:00:00Z") }
  let(:output) { StringIO.new }
  let(:item_options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }

  def run_backfill(dry_run: false)
    travel_to(backfilled_at) { described_class.run!(dry_run:, backfilled_at:, output:) }
  end

  def create_item(klass, attributes)
    travel_to(item_observed_at) do
      klass.create!({ options: item_options, title: "Buy milk" }.merge(attributes))
    end
  end

  def create_collection(confidence:, method:)
    travel_to(mapping_observed_at) do
      SyncCollection.create!(
        title: "Release checklist",
        mapping_method: method,
        mapping_confidence: confidence,
        mapping_metadata: { "note_key" => "omnifocus_id" }
      )
    end
  end

  # One representative record per required service (#222 acceptance):
  # OmniFocus and Google Tasks are single-instance (default token), Asana
  # and GitHub carry configured instances.
  def create_representative_items(collection: nil)
    create_item(Omnifocus::Task,
                external_id: "of-1", source_service_name: "Omnifocus",
                notes: "asana_work_id: asana-9", sync_collection: collection)
    create_item(Asana::Task,
                external_id: "asana-9", source_service_name: "Asana:work",
                notes: "omnifocus_id: of-1", sync_collection: collection)
    create_item(Github::Issue,
                external_id: "issue-42", source_service_name: "Github:repo-1",
                url: "https://github.com/repo-1/issues/42")
    create_item(GoogleTasks::Task,
                external_id: "gt-7", source_service_name: "GoogleTasks",
                completed: true, completed_at: Time.zone.parse("2026-10-09T08:00:00Z"))
  end

  describe "baseline item snapshots" do
    it "enqueues one item row per existing sync item for each representative service" do
      create_representative_items

      summary = run_backfill

      rows = OutboxEntry.where(record_kind: "item").order(:external_id)
      expect(rows.map(&:service_type)).to contain_exactly("omnifocus", "asana", "github", "google_tasks")
      expect(summary[:items]).to include(
        enqueued: 4,
        by_service: { "omnifocus" => 1, "asana" => 1, "github" => 1, "google_tasks" => 1 }
      )

      omnifocus = rows.find { |row| row.service_type == "omnifocus" }
      expect(omnifocus).to have_attributes(
        service_instance: "omnifocus:default",
        external_id: "of-1",
        observed_at: item_observed_at,
        event_type: nil
      )
      expect(omnifocus.idempotency_key).to eq("tb:v1:item:omnifocus:default:of-1:snapshot:2026-10-10T09:00:00.000000Z")
      expect(omnifocus.payload).to include(
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
        "provenance" => {
          "detected_by" => "backfill",
          "backfilled_at" => "2026-10-10T12:00:00.000000Z"
        }
      )

      asana = rows.find { |row| row.service_type == "asana" }
      expect(asana.service_instance).to eq("asana:work")
      google_tasks = rows.find { |row| row.service_type == "google_tasks" }
      expect(google_tasks.payload).to include("status" => "completed", "completed_at" => "2026-10-09T08:00:00.000000Z")
      github = rows.find { |row| row.service_type == "github" }
      expect(github.payload["source"]).to include("service_instance" => "github:repo-1",
                                                  "source_url" => "https://github.com/repo-1/issues/42")
    end

    it "marks rows as baseline observations, never change events or sync runs" do
      create_representative_items

      run_backfill

      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
      expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
      OutboxEntry.where(record_kind: "item").each do |row|
        expect(row.payload["provenance"]).to eq(
          "detected_by" => "backfill",
          "backfilled_at" => "2026-10-10T12:00:00.000000Z"
        )
      end
    end

    it "falls back to the record's updated_at when no observation was ever recorded" do
      legacy = create_item(Omnifocus::Task, external_id: "of-legacy", source_service_name: "Omnifocus")
      legacy.update_columns(last_observed_at: nil, first_observed_at: nil)
      updated_at = legacy.updated_at

      run_backfill

      row = OutboxEntry.find_by(record_kind: "item", external_id: "of-legacy")
      expect(row.observed_at).to eq(updated_at)
    end
  end

  describe "collection mappings" do
    it "enqueues confirmed and inferred memberships and withholds low-confidence ones" do
      confirmed = create_collection(confidence: "high", method: "source_sync_id")
      create_item(Omnifocus::Task, external_id: "of-1", source_service_name: "Omnifocus", sync_collection: confirmed)
      create_item(Asana::Task, external_id: "asana-9", source_service_name: "Asana:work", sync_collection: confirmed)
      inferred = create_collection(confidence: "medium", method: "title_fallback")
      create_item(Github::Issue, external_id: "issue-42", source_service_name: "Github:repo-1", sync_collection: inferred)
      tentative = create_collection(confidence: "low", method: "manual_backfill")
      create_item(GoogleTasks::Task, external_id: "gt-7", source_service_name: "GoogleTasks", sync_collection: tentative)

      summary = run_backfill

      rows = OutboxEntry.where(record_kind: "mapping")
      expect(rows.count).to eq(3)
      expect(rows.map(&:sync_collection_id)).to contain_exactly(confirmed.id, confirmed.id, inferred.id)
      expect(rows.find { |row| row.sync_collection_id == inferred.id }.payload).to include(
        "mapping_confidence" => "inferred",
        "mapping_source" => "title_match",
        "provenance" => including(
          "detected_by" => "backfill",
          "backfilled_at" => "2026-10-10T12:00:00.000000Z"
        )
      )
      expect(rows.map(&:idempotency_key)).to include(
        "tb:v1:map:sync_collection:#{confirmed.id}:membership:omnifocus:default:of-1:2026-10-10T10:00:00.000000Z"
      )
      expect(OutboxEntry.where(record_kind: "mapping", external_id: "gt-7")).to be_empty
      expect(summary[:mappings]).to include(
        enqueued: 3,
        by_confidence: { "confirmed" => 2, "inferred" => 1 },
        withheld: { "tentative" => 1 }
      )
    end

    it "skips collections without mapping metadata as incomplete" do
      incomplete = SyncCollection.create!(title: "Never backfilled")
      create_item(Github::Issue, external_id: "issue-42", source_service_name: "Github:repo-1", sync_collection: incomplete)

      summary = run_backfill

      expect(OutboxEntry.where(record_kind: "mapping")).to be_empty
      expect(summary[:mappings][:skipped]).to eq("missing_mapping_metadata" => { "collections" => 1 })
    end

    it "skips members without an external id and reports them by service" do
      confirmed = create_collection(confidence: "high", method: "source_sync_id")
      create_item(Asana::Task, external_id: nil, source_service_name: "Asana:work", sync_collection: confirmed)

      summary = run_backfill

      expect(OutboxEntry.where(record_kind: "mapping")).to be_empty
      expect(summary[:mappings][:skipped]).to eq("missing_external_id" => { "asana" => 1 })
    end
  end

  describe "idempotency" do
    it "leaves previously enqueued rows untouched when run again" do
      collection = create_collection(confidence: "high", method: "source_sync_id")
      create_representative_items(collection:)
      run_backfill
      first_rows = OutboxEntry.all.to_a
      first_items = Base::SyncItem.all.to_a

      travel_to(backfilled_at + 1.hour) { described_class.run!(backfilled_at: backfilled_at + 1.hour, output:) }

      expect(OutboxEntry.all.to_a).to contain_exactly(*first_rows)
      expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
      expect(OutboxEntry.where(record_kind: "mapping").count).to eq(2)
      first_items.each { |item| expect(item.reload.last_observed_at).to eq(item_observed_at) }
    end

    it "does not mutate local sync data or external source systems" do
      collection = create_collection(confidence: "high", method: "source_sync_id")
      create_representative_items(collection:)
      items_before = Base::SyncItem.all.map { |item| item.slice(:id, :updated_at, :last_observed_at, :notes) }
      collections_before = SyncCollection.all.map { |c| c.slice(:id, :updated_at, :mapping_last_observed_at, :mapping_method) }
      allow(Base::Service).to receive(:resolve_service_class).and_call_original

      run_backfill

      expect(Base::Service).not_to have_received(:resolve_service_class)
      expect(SyncCollection.all.map { |c| c.slice(:id, :updated_at, :mapping_last_observed_at, :mapping_method) })
        .to eq(collections_before)
      expect(Base::SyncItem.all.map { |item| item.slice(:id, :updated_at, :last_observed_at, :notes) })
        .to eq(items_before)
    end
  end

  describe "dry run" do
    it "enqueues nothing and reports counts by service, confidence, and skipped records" do
      confirmed = create_collection(confidence: "high", method: "source_sync_id")
      create_representative_items(collection: confirmed)
      tentative = create_collection(confidence: "low", method: "manual_backfill")
      create_item(GoogleTasks::Task, external_id: "gt-9", source_service_name: "GoogleTasks", sync_collection: tentative)
      SyncCollection.create!(title: "Never backfilled")

      summary = run_backfill(dry_run: true)

      expect(OutboxEntry.count).to eq(0)
      expect(summary).to include(dry_run: true)
      expect(summary[:items]).to include(by_service: { "omnifocus" => 1, "asana" => 1, "github" => 1, "google_tasks" => 2 })
      expect(summary[:mappings]).to include(
        by_confidence: { "confirmed" => 2 },
        withheld: { "tentative" => 1 },
        skipped: { "missing_mapping_metadata" => { "collections" => 1 } }
      )

      report = output.string
      expect(report).to include("Outbox baseline backfill (dry run — nothing was enqueued)")
      expect(report).to include("Item snapshots (would be enqueued): 5")
      expect(report).to include("omnifocus: 1")
      expect(report).to include("Mapping memberships (would be enqueued): 2")
      expect(report).to include("confirmed: 2")
      expect(report).to include("Withheld mappings (not published; review locally): 1")
      expect(report).to include("tentative: 1")
      expect(report).to include("missing_mapping_metadata:")
    end
  end
end
