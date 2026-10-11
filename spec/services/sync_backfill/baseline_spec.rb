# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Baseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:backfilled_at) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:observed_at) { Time.zone.parse("2026-10-10T09:30:00Z") }
  let(:options) { { services: [], primary: "Omnifocus", tags: [] } }

  def create_item(klass, service_name:, **attributes)
    klass.create!(options: options.merge(service_name:), **attributes).tap do |item|
      item.update_columns(last_observed_at: observed_at, first_observed_at: observed_at)
    end
  end

  describe "baseline item snapshots" do
    it "enqueues one item row per existing item for each representative service" do
      create_item(Omnifocus::Task, service_name: "Omnifocus",
                                   title: "Buy milk", external_id: "of-1",
                                   notes: "pick up two\nasana_work_id: asana-9",
                                   url: "omnifocus:///task/of-1",
                                   last_modified: Time.zone.parse("2026-10-10T08:00:00Z"))
      create_item(Asana::Task, service_name: "Asana:work",
                               title: "Buy milk", external_id: "asana-9",
                               due_at: Time.zone.parse("2026-10-12T17:00:00Z"))
      create_item(Github::Issue, service_name: "Github:repo-1",
                                 title: "Fix sync", external_id: "issue-42", status: "open")
      create_item(GoogleTasks::Task, service_name: "GoogleTasks",
                                     title: "Buy oat milk", external_id: "gt-7", completed: true,
                                     completed_at: Time.zone.parse("2026-10-08T10:00:00Z"))

      summary = described_class.run!(now: backfilled_at)

      expect(summary).to include(dry_run: false)
      expect(summary[:items]).to include(considered: 4, enqueued: 4, skipped_incomplete: 0)
      expect(summary[:items][:by_service]).to eq(
        "asana" => { enqueued: 1, skipped_incomplete: 0 },
        "github" => { enqueued: 1, skipped_incomplete: 0 },
        "google_tasks" => { enqueued: 1, skipped_incomplete: 0 },
        "omnifocus" => { enqueued: 1, skipped_incomplete: 0 }
      )

      rows = OutboxEntry.where(record_kind: "item")
      expect(rows.map(&:service_instance)).to contain_exactly(
        "omnifocus:default", "asana:work", "github:repo-1", "google_tasks:default"
      )

      omnifocus_row = rows.find { |row| row.service_type == "omnifocus" }
      expect(omnifocus_row).to have_attributes(
        external_id: "of-1",
        observed_at: observed_at,
        source_updated_at: Time.zone.parse("2026-10-10T08:00:00Z"),
        event_type: nil,
        status: "pending"
      )
      expect(omnifocus_row.idempotency_key).to eq(
        "tb:v1:item:omnifocus:default:of-1:snapshot:2026-10-10T09:30:00.000000Z"
      )
      expect(omnifocus_row.payload).to include(
        "contract_version" => 1,
        "item_key" => "omnifocus:of-1",
        "entity_type" => "task",
        "title" => "Buy milk",
        "display_title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false,
        "observed_at" => "2026-10-10T09:30:00.000000Z",
        "source_updated_at" => "2026-10-10T08:00:00.000000Z",
        "started_at" => nil
      )
      expect(omnifocus_row.payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-1",
        "source_url" => "omnifocus:///task/of-1"
      )
      expect(omnifocus_row.payload["provenance"]).to eq(
        "detected_by" => "backfill",
        "backfilled_at" => "2026-10-11T12:00:00.000000Z"
      )
      expect(omnifocus_row.payload["notes_digest"]).to be_present
      expect(omnifocus_row.payload).not_to include("notes_preview")
      expect(omnifocus_row.payload).not_to include("tags")

      asana_row = rows.find { |row| row.service_type == "asana" }
      expect(asana_row.payload["item_key"]).to eq("asana_work:asana-9")
      expect(asana_row.payload["due_at"]).to eq("2026-10-12T17:00:00.000000Z")

      google_tasks_row = rows.find { |row| row.service_type == "google_tasks" }
      expect(google_tasks_row.payload).to include(
        "status" => "completed",
        "completed_at" => "2026-10-08T10:00:00.000000Z"
      )
    end

    it "skips incomplete items without an external id and reports them" do
      create_item(Asana::Task, service_name: "Asana:work", title: "Has id", external_id: "asana-3")
      Asana::Task.create!(title: "No id", options: options.merge(service_name: "Asana:work"))

      summary = described_class.run!(now: backfilled_at)

      expect(summary[:items]).to include(considered: 2, enqueued: 1, skipped_incomplete: 1)
      expect(summary[:items][:by_service]).to include(
        "asana" => { enqueued: 1, skipped_incomplete: 1 }
      )
      expect(OutboxEntry.where(record_kind: "item").map(&:external_id)).to eq(["asana-3"])
    end

    it "carries parent and sync_collection context on item rows" do
      collection = SyncCollection.create!(
        title: "Pair", mapping_method: "source_sync_id", mapping_confidence: "high"
      )
      parent = create_item(Omnifocus::Task, service_name: "Omnifocus",
                                            title: "Parent", external_id: "of-p")
      create_item(Omnifocus::Task, service_name: "Omnifocus",
                                   title: "Child", external_id: "of-c",
                                   parent_item_id: parent.id, sync_collection: collection)

      described_class.run!(now: backfilled_at)

      child_row = OutboxEntry.find_by(record_kind: "item", external_id: "of-c")
      expect(child_row.payload["parent"]).to eq(
        "external_id" => "of-p",
        "item_key" => "omnifocus:of-p"
      )
      expect(child_row.payload["sync_collection"]).to include(
        "sync_collection_id" => collection.id,
        "membership_role" => "member",
        "mapping_confidence" => "confirmed",
        "mapping_source" => "sync_id_note"
      )
    end
  end

  describe "mapping rows" do
    it "publishes high and medium confidence mappings and withholds low confidence" do
      confirmed_collection = SyncCollection.create!(
        title: "Release checklist", mapping_method: "source_sync_id", mapping_confidence: "high"
      )
      inferred_collection = SyncCollection.create!(
        title: "Buy milk", mapping_method: "title_fallback", mapping_confidence: "medium"
      )
      withheld_collection = SyncCollection.create!(
        title: "Maybe linked", mapping_method: "manual_backfill", mapping_confidence: "low"
      )
      create_item(Omnifocus::Task, service_name: "Omnifocus",
                                   title: "Release checklist", external_id: "of-2",
                                   sync_collection: confirmed_collection)
      create_item(Asana::Task, service_name: "Asana:work",
                               title: "Release checklist", external_id: "asana-2",
                               sync_collection: confirmed_collection)
      create_item(Github::Issue, service_name: "Github:repo-1",
                                 title: "Buy milk", external_id: "issue-7",
                                 sync_collection: inferred_collection)
      create_item(GoogleTasks::Task, service_name: "GoogleTasks",
                                     title: "Maybe linked", external_id: "gt-9",
                                     sync_collection: withheld_collection)

      summary = described_class.run!(now: backfilled_at)

      mapping_rows = OutboxEntry.where(record_kind: "mapping")
      expect(mapping_rows.map(&:external_id)).to contain_exactly("of-2", "asana-2", "issue-7")
      expect(mapping_rows.select { |row| row.sync_collection_id == confirmed_collection.id }
                         .map { |row| row.payload["mapping_confidence"] }).to all(eq("confirmed"))
      expect(mapping_rows.find { |row| row.sync_collection_id == inferred_collection.id }
                         .payload["mapping_confidence"]).to eq("inferred")
      expect(mapping_rows.map(&:service_instance)).to contain_exactly(
        "omnifocus:default", "asana:work", "github:repo-1"
      )

      expect(summary[:mappings]).to include(
        collections: 3, memberships: 4, enqueued: 3,
        withheld_low_confidence: 1, skipped_incomplete: 0
      )
      expect(summary[:mappings][:by_confidence]).to eq("high" => 2, "low" => 1, "medium" => 1)
      expect(summary[:mappings][:by_method]).to eq(
        "manual_backfill" => 1, "source_sync_id" => 2, "title_fallback" => 1
      )
    end

    it "skips members without an external id" do
      collection = SyncCollection.create!(
        title: "Pair", mapping_method: "source_sync_id", mapping_confidence: "high"
      )
      create_item(Asana::Task, service_name: "Asana:work",
                               title: "Has id", external_id: "asana-4",
                               sync_collection: collection)
      Omnifocus::Task.create!(title: "No id", options: options.merge(service_name: "Omnifocus"),
                              sync_collection: collection)

      summary = described_class.run!(now: backfilled_at)

      expect(summary[:mappings]).to include(
        memberships: 2, enqueued: 1, withheld_low_confidence: 0, skipped_incomplete: 1
      )
      expect(OutboxEntry.where(record_kind: "mapping").map(&:external_id)).to eq(["asana-4"])
    end
  end

  describe "idempotency and safety" do
    it "reuses stored rows on rerun without duplicating or mutating them" do
      collection = SyncCollection.create!(
        title: "Pair", mapping_method: "source_sync_id", mapping_confidence: "high"
      )
      create_item(Omnifocus::Task, service_name: "Omnifocus",
                                   title: "Buy milk", external_id: "of-5",
                                   sync_collection: collection)
      create_item(Asana::Task, service_name: "Asana:work",
                               title: "Buy milk", external_id: "asana-5",
                               sync_collection: collection)
      described_class.run!(now: backfilled_at)
      snapshot = lambda do
        OutboxEntry.order(:id).to_a.map { |row| [row.idempotency_key, row.payload, row.updated_at] }
      end
      first_run = snapshot.call

      summary = described_class.run!(now: backfilled_at + 1.hour)

      expect(snapshot.call).to eq(first_run)
      expect(OutboxEntry.count).to eq(first_run.length)
      expect(summary[:items]).to include(enqueued: 2)
      expect(summary[:mappings]).to include(enqueued: 2)
    end

    it "writes nothing in dry-run mode but reports the same counts" do
      collection = SyncCollection.create!(
        title: "Pair", mapping_method: "source_sync_id", mapping_confidence: "high"
      )
      withheld = SyncCollection.create!(
        title: "Maybe", mapping_method: "manual_backfill", mapping_confidence: "low"
      )
      create_item(Omnifocus::Task, service_name: "Omnifocus",
                                   title: "Buy milk", external_id: "of-6",
                                   sync_collection: collection)
      create_item(Asana::Task, service_name: "Asana:work",
                               title: "Buy milk", external_id: "asana-6",
                               sync_collection: collection)
      create_item(Github::Issue, service_name: "Github:repo-1",
                                 title: "Maybe", external_id: "issue-9",
                                 sync_collection: withheld)

      summary = described_class.run!(dry_run: true, now: backfilled_at)

      expect(summary[:dry_run]).to be(true)
      expect(summary[:items]).to include(considered: 3, enqueued: 3)
      expect(summary[:mappings]).to include(enqueued: 2, withheld_low_confidence: 1)
      expect(OutboxEntry.count).to eq(0)
    end

    it "does not mutate existing sync data or emit observation or sync_run rows" do
      item = create_item(Asana::Task, service_name: "Asana:work",
                                      title: "Buy milk", external_id: "asana-7",
                                      last_modified: Time.zone.parse("2026-10-09T08:00:00Z"))
      tracked_attributes = %w[
        title external_id notes url last_modified last_observed_at first_observed_at
        source_updated_at source_service_name updated_at
      ]
      before = item.attributes.slice(*tracked_attributes)

      described_class.run!(now: backfilled_at)

      expect(item.reload.attributes.slice(*tracked_attributes)).to eq(before)
      expect(OutboxEntry.where(record_kind: %w[observation sync_run])).to be_empty
      expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
    end
  end

  describe ".format" do
    it "renders the summary as reviewable lines" do
      summary = {
        dry_run: true,
        items: { considered: 2, enqueued: 1, skipped_incomplete: 1,
                 by_service: { "asana" => { enqueued: 1, skipped_incomplete: 1 } } },
        mappings: { collections: 1, memberships: 2, enqueued: 1, withheld_low_confidence: 1,
                    skipped_incomplete: 0, by_confidence: { "high" => 1, "low" => 1 },
                    by_method: { "manual_backfill" => 1, "source_sync_id" => 1 } }
      }

      expect(described_class.format(summary)).to eq(
        [
          "Baseline backfill (dry run):",
          "  items: 2 considered, 1 enqueued, 1 skipped (no external id)",
          "  items by service: asana=1 enqueued/1 skipped",
          "  mappings: 1 collections, 2 memberships, 1 enqueued, 1 withheld (low confidence), 0 skipped (no external id)",
          "  mappings by confidence: high=1, low=1",
          "  mappings by method: manual_backfill=1, source_sync_id=1"
        ].join("\n")
      )
    end
  end

  describe ".provenance_pending?" do
    it "is true while items or collections lack backfilled provenance" do
      expect(described_class.provenance_pending?).to be(false)

      item = create_item(Asana::Task, service_name: "Asana:work",
                                      title: "Buy milk", external_id: "asana-8")
      item.update_columns(last_observed_at: nil)
      expect(described_class.provenance_pending?).to be(true)

      item.update_columns(last_observed_at: observed_at)
      expect(described_class.provenance_pending?).to be(false)

      SyncCollection.create!(title: "Unmapped")
      expect(described_class.provenance_pending?).to be(true)
    end
  end
end
