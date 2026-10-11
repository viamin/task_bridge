# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::Backfill do
  include ActiveSupport::Testing::TimeHelpers

  let(:backfilled_at) { Time.zone.parse("2026-10-11T09:00:00Z") }
  let(:observed_at) { Time.zone.parse("2026-10-10T08:00:00Z") }

  # Representative existing records across services with real STI classes:
  # identity must come from persisted columns, never from provider APIs.
  let!(:omnifocus_task) do
    Omnifocus::Task.create!(title: "Buy milk", external_id: "of-1", url: "omnifocus:///task/of-1",
                            last_modified: observed_at - 1.day)
  end
  let!(:asana_task) do
    Asana::Task.create!(title: "Buy oat milk", external_id: "asana-1",
                        options: { service_name: "Asana:work", services: [], primary: "Omnifocus", tags: [] },
                        completed_at: observed_at - 2.days, last_modified: observed_at - 2.days)
  end
  let!(:github_issue) do
    Github::Issue.create!(title: "Fix login bug", external_id: "gh-1", status: "closed",
                          last_modified: observed_at - 3.days)
  end
  let!(:google_task) do
    GoogleTasks::Task.create!(title: "Buy milk", external_id: "gt-1", notes: "asana_work_id: asana-1",
                              last_modified: observed_at - 1.hour)
  end

  before do
    [omnifocus_task, asana_task, github_issue, google_task].each do |item|
      item.update_columns(last_observed_at: observed_at, first_observed_at: observed_at)
    end
  end

  def run_backfill(dry_run: false)
    described_class.run!(dry_run:, now: backfilled_at)
  end

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  describe "baseline item snapshots" do
    it "enqueues one item row per existing sync item with local-column identity" do
      run_backfill

      aggregate_failures do
        expect(item_rows.count).to eq(4)
        expect(OutboxEntry.where(record_kind: "observation")).to be_empty
        expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty

        omnifocus_row = item_rows.find_by(external_id: "of-1")
        expect(omnifocus_row).to have_attributes(
          service_type: "omnifocus",
          service_instance: "omnifocus:default",
          observed_at: observed_at,
          source_updated_at: observed_at - 1.day
        )
        expect(omnifocus_row.idempotency_key)
          .to eq("tb:v1:item:omnifocus:default:of-1:snapshot:#{observed_at.utc.iso8601(6)}")

        expect(item_rows.find_by(external_id: "asana-1").service_instance).to eq("asana:work")
        expect(item_rows.find_by(external_id: "gh-1").service_instance).to eq("github:default")
        expect(item_rows.find_by(external_id: "gt-1").service_instance).to eq("google_tasks:default")
      end
    end

    it "marks the snapshot as a backfill baseline, not a change event" do
      run_backfill

      payload = item_rows.find_by(external_id: "of-1").payload
      aggregate_failures do
        expect(payload).to include(
          "contract_version" => 1,
          "item_key" => "omnifocus:of-1",
          "entity_type" => "task",
          "observed_at" => observed_at.utc.iso8601(6),
          "backfilled_at" => backfilled_at.utc.iso8601(6),
          "title" => "Buy milk",
          "status" => "open",
          "is_deleted" => false,
          "source_updated_at" => (observed_at - 1.day).utc.iso8601(6),
          "provenance" => { "detected_by" => "backfill" }
        )
        expect(payload["source"]).to include(
          "service_type" => "omnifocus",
          "service_instance" => "omnifocus:default",
          "external_id" => "of-1",
          "source_url" => "omnifocus:///task/of-1"
        )
        expect(payload).not_to have_key("notes_preview")
        expect(payload).not_to have_key("sync_collection")
      end
    end

    it "normalizes completion state from persisted columns" do
      run_backfill

      aggregate_failures do
        expect(item_rows.find_by(external_id: "asana-1").payload).to include(
          "status" => "completed",
          "completed_at" => (observed_at - 2.days).utc.iso8601(6)
        )
        expect(item_rows.find_by(external_id: "gh-1").payload).to include("status" => "completed")
        expect(item_rows.find_by(external_id: "gt-1").payload).to include("status" => "open")
      end
    end

    it "summarizes enqueued items by service" do
      summary = run_backfill

      expect(summary[:items]).to eq(
        enqueued: { "asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1 },
        already_enqueued: {},
        skipped: {}
      )
    end
  end

  describe "idempotency" do
    it "writes no duplicate rows on reruns and preserves delivery state" do
      run_backfill
      delivered = item_rows.find_by(external_id: "of-1")
      delivered.mark_delivered!
      keys = OutboxEntry.pluck(:idempotency_key)

      summary = run_backfill

      aggregate_failures do
        expect(OutboxEntry.pluck(:idempotency_key)).to eq(keys)
        expect(item_rows.count).to eq(4)
        expect(delivered.reload).to be_delivered
        expect(summary[:items]).to eq(
          enqueued: {},
          already_enqueued: { "asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1 },
          skipped: {}
        )
      end
    end

    it "rebuilds the same idempotency keys from unchanged rows" do
      run_backfill

      keys = OutboxEntry.pluck(:idempotency_key).sort
      OutboxEntry.delete_all

      run_backfill

      expect(OutboxEntry.pluck(:idempotency_key).sort).to eq(keys)
    end
  end

  describe "skipped and incomplete records" do
    it "counts items without an external id instead of enqueueing them" do
      omnifocus_task.update_columns(external_id: nil, source_external_id: nil)

      summary = run_backfill

      aggregate_failures do
        expect(item_rows.count).to eq(3)
        expect(summary[:items][:skipped]).to eq("omnifocus/missing_external_id" => 1)
      end
    end

    it "counts rows whose STI type no longer resolves instead of aborting" do
      Base::SyncItem.insert_all(
        [
          { type: nil, title: "legacy untyped", created_at: observed_at, updated_at: observed_at },
          { type: "Legacy::Task", title: "legacy class", created_at: observed_at, updated_at: observed_at },
          { type: "String", title: "non-item class", created_at: observed_at, updated_at: observed_at }
        ]
      )

      summary = run_backfill

      aggregate_failures do
        expect(item_rows.count).to eq(4)
        expect(summary[:items][:skipped]).to eq(
          "Legacy::Task/unresolvable_item_type" => 1,
          "String/unresolvable_item_type" => 1,
          "untyped/unresolvable_item_type" => 1
        )
      end
    end
  end

  describe "sync collection mappings" do
    it "enqueues mapping rows for confirmed memberships" do
      collection = SyncCollection.create!(title: "Buy milk", mapping_method: "source_sync_id", mapping_confidence: "high",
                                          mapping_last_observed_at: observed_at)
      omnifocus_task.update_columns(sync_collection_id: collection.id)
      google_task.update_columns(sync_collection_id: collection.id)

      summary = run_backfill

      aggregate_failures do
        expect(mapping_rows.count).to eq(2)
        expect(mapping_rows.map(&:external_id)).to contain_exactly("of-1", "gt-1")

        row = mapping_rows.find_by(external_id: "gt-1")
        expect(row).to have_attributes(
          service_type: "google_tasks",
          service_instance: "google_tasks:default",
          sync_collection_id: collection.id,
          observed_at: observed_at
        )
        expect(row.idempotency_key).to eq(
          "tb:v1:map:sync_collection:#{collection.id}:membership:google_tasks:default:gt-1:#{observed_at.utc.iso8601(6)}"
        )
        expect(row.payload).to include(
          "mapping_type" => "representation_membership",
          "mapping_confidence" => "confirmed",
          "mapping_source" => "sync_id_note",
          "membership_role" => "member",
          "backfilled_at" => backfilled_at.utc.iso8601(6),
          "sync_collection" => { "sync_collection_id" => collection.id, "title" => "Buy milk" }
        )
        expect(row.payload["member"]).to include(
          "item_key" => "google_tasks:gt-1",
          "service_type" => "google_tasks",
          "service_instance" => "google_tasks:default",
          "external_id" => "gt-1"
        )
        expect(row.payload["provenance"]).to include("detected_by" => "backfill", "method" => "source_sync_id")
        expect(summary[:mappings]).to eq(
          enqueued: { "confirmed" => 2 }, already_enqueued: {}, withheld: {}, skipped: {}
        )
      end
    end

    it "withholds low-confidence memberships from publication but counts them" do
      collection = SyncCollection.create!(title: "Buy milk", mapping_method: "manual_backfill", mapping_confidence: "low",
                                          mapping_last_observed_at: observed_at)
      omnifocus_task.update_columns(sync_collection_id: collection.id)
      asana_task.update_columns(sync_collection_id: collection.id)

      summary = run_backfill

      aggregate_failures do
        expect(mapping_rows).to be_empty
        expect(summary[:mappings]).to eq(
          enqueued: {}, already_enqueued: {}, withheld: { "low" => 2 }, skipped: {}
        )
      end
    end

    it "backfills missing mapping provenance locally, then publishes what it supports" do
      travel_to(observed_at) do
        collection = SyncCollection.create!(title: "Buy milk")
        omnifocus_task.update_columns(sync_collection_id: collection.id)
        google_task.update_columns(sync_collection_id: collection.id)
      end

      summary = run_backfill

      collection = SyncCollection.find_by(title: "Buy milk")
      aggregate_failures do
        # google_task's parsed notes reference the asana item, but the
        # omnifocus task only matches by title: the strongest pairwise
        # evidence ranks the collection.
        expect(collection.mapping_method).to eq("title_fallback")
        expect(collection.mapping_confidence).to eq("medium")
        expect(mapping_rows.count).to eq(2)
        expect(mapping_rows.map { |row| row.payload["mapping_confidence"] }).to eq(%w[inferred inferred])
        expect(summary[:mappings][:enqueued]).to eq("inferred" => 2)
      end
    end

    it "counts collections without members instead of failing" do
      SyncCollection.create!(title: "orphan", mapping_method: "source_sync_id", mapping_confidence: "high")

      summary = run_backfill

      expect(summary[:mappings][:skipped]).to eq("collection_without_members" => 1)
    end
  end

  describe "dry run" do
    it "summarizes without writing outbox rows" do
      summary = run_backfill(dry_run: true)

      aggregate_failures do
        expect(OutboxEntry.count).to eq(0)
        expect(summary[:dry_run]).to be(true)
        expect(summary[:items][:enqueued]).to eq({ "asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1 })
      end
    end

    it "reports rows a previous run already enqueued" do
      run_backfill

      summary = run_backfill(dry_run: true)

      expect(summary[:items]).to eq(
        enqueued: {},
        already_enqueued: { "asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1 },
        skipped: {}
      )
    end
  end

  describe "locality" do
    it "never mutates external-facing item state or live diff baselines" do
      expect do
        run_backfill
      end.not_to(change { ExternalItemState.snapshot_of(omnifocus_task, asana_task, github_issue, google_task) })

      aggregate_failures do
        expect(omnifocus_task.reload.last_snapshot).to be_nil
        expect(github_issue.reload.last_snapshot).to be_nil
        expect(item_rows.count).to eq(4)
      end
    end
  end
end

# External-facing columns plus the live pipeline's diff baseline: the
# backfill reads these but must never rewrite them (external source
# systems and the live observation pipeline own that state).
module ExternalItemState
  module_function

  def snapshot_of(*items)
    items.map do |item|
      item.reload
      item.attributes.slice("title", "notes", "url", "external_id", "source_external_id", "source_url",
                            "last_modified", "last_observed_at", "completed_at", "last_snapshot", "updated_at")
    end
  end
end
