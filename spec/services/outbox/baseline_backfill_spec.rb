# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::BaselineBackfill do
  include ActiveSupport::Testing::TimeHelpers

  let(:run_at) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:established_at) { Time.zone.parse("2026-10-01T09:00:00Z") }
  let(:base_options) { { services: [], primary: "Omnifocus", tags: [] } }

  # Representative records across services: the primary (OmniFocus), a
  # named-instance service (Asana:work), a repository-scoped service
  # (Github:repo-1), and a single-instance service (Google Tasks).
  let!(:omnifocus_task) { Omnifocus::Task.create!(title: "Buy milk", external_id: "of-1", options: base_options) }
  let!(:asana_task) do
    Asana::Task.create!(title: "Ship the release", external_id: "asana-9", options: base_options.merge(service_name: "Asana:work"))
  end
  let!(:github_issue) do
    Github::Issue.create!(title: "Fix the bug", external_id: "gh-42", status: "open", options: base_options.merge(service_name: "Github:repo-1"))
  end
  let!(:google_task) do
    GoogleTasks::Task.create!(title: "Remember the milk", external_id: "gt-7", options: base_options.merge(service_name: "GoogleTasks"))
  end

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  describe "baseline item snapshots" do
    it "seeds one item snapshot per existing sync item, marked as backfill" do
      summary = travel_to(run_at) { described_class.run! }

      expect(item_rows.map(&:service_type)).to contain_exactly("omnifocus", "asana", "github", "google_tasks")
      expect(item_rows.map(&:service_instance))
        .to contain_exactly("omnifocus:default", "asana:work", "github:repo-1", "google_tasks:default")

      row = item_rows.find { |entry| entry.service_type == "omnifocus" }
      expect(row.observed_at).to eq(omnifocus_task.first_observed_at)
      expect(row.idempotency_key).to eq(
        Outbox::IdempotencyKey.for(
          record_kind: :item, observed_at: row.observed_at,
          service_instance: "omnifocus:default", external_id: "of-1"
        )
      )
      expect(row.payload).to include(
        "contract_version" => OutboxEntry::PAYLOAD_VERSION,
        "item_key" => "omnifocus:of-1",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false
      )
      expect(row.payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-1"
      )
      expect(row.payload["provenance"]).to include(
        "detected_by" => "backfill",
        "backfilled_at" => run_at.utc.iso8601(6)
      )
      expect(row.payload["observed_at"]).to eq(row.observed_at.utc.iso8601(6))
      expect(summary[:items]).to include(
        candidates: 4, enqueued: 4, already_present: 0, skipped_incomplete: 0, write_failures: 0
      )
    end

    it "uses each item's stable item key so backfilled and live rows identify the same item" do
      travel_to(run_at) { described_class.run! }

      expect(item_rows.map { |row| row.payload["item_key"] })
        .to contain_exactly("omnifocus:of-1", "asana_work:asana-9", "github_repo_1:gh-42", "google_tasks:gt-7")
    end

    it "creates no observation or sync_run rows" do
      travel_to(run_at) { described_class.run! }

      expect(OutboxEntry.where(record_kind: %w[observation sync_run])).to be_empty
    end
  end

  describe "baseline mapping rows" do
    let!(:confirmed_collection) do
      SyncCollection.create!(title: "Linked by sync id", mapping_method: "source_sync_id", mapping_confidence: "high",
                             mapping_established_at: established_at, sync_items: [omnifocus_task, asana_task])
    end
    let!(:inferred_collection) do
      SyncCollection.create!(title: "Linked by title", mapping_method: "title_fallback", mapping_confidence: "medium",
                             mapping_established_at: established_at, sync_items: [github_issue])
    end
    let!(:withheld_collection) do
      SyncCollection.create!(title: "Loosely grouped", mapping_method: "manual_backfill", mapping_confidence: "low",
                             mapping_established_at: established_at, sync_items: [google_task])
    end
    let!(:unknown_collection) { SyncCollection.create!(title: "Never assessed") }

    it "enqueues confirmed and inferred memberships and withholds low-confidence ones" do
      summary = travel_to(run_at) { described_class.run! }

      expect(mapping_rows.count).to eq(3)
      expect(mapping_rows.map { |row| row.payload["mapping_confidence"] }).to contain_exactly("confirmed", "confirmed", "inferred")

      row = mapping_rows.find { |entry| entry.external_id == "of-1" }
      expect(row.sync_collection_id).to eq(confirmed_collection.id)
      expect(row.observed_at).to eq(established_at)
      expect(row.idempotency_key).to eq(
        Outbox::IdempotencyKey.for(
          record_kind: :mapping, observed_at: established_at, sync_collection_id: confirmed_collection.id,
          service_instance: "omnifocus:default", external_id: "of-1"
        )
      )
      expect(row.payload["provenance"]).to include(
        "method" => "source_sync_id",
        "confidence" => "high",
        "detected_by" => "backfill",
        "backfilled_at" => run_at.utc.iso8601(6)
      )
      expect(summary[:mappings]).to include(
        collections: 4, memberships: 4, enqueued: 3, already_present: 0, withheld: 1, skipped_incomplete: 0
      )
      expect(summary[:mappings][:by_confidence]).to include(
        "high" => including(enqueued: 2),
        "medium" => including(enqueued: 1),
        "low" => including(withheld: 1)
      )
    end

    it "keeps the withheld memberships identifiable through the summary" do
      summary = travel_to(run_at) { described_class.run!(dry_run: true) }

      expect(summary[:mappings][:by_confidence]["low"]).to include(withheld: 1)
      expect(mapping_rows).to be_empty
    end
  end

  describe "idempotency" do
    it "creates no duplicate rows and never rewrites stored payloads on reruns" do
      first_summary = travel_to(run_at) { described_class.run! }
      first_rows = OutboxEntry.all.to_a
      backfilled_at = item_rows.find { |row| row.external_id == "of-1" }.payload["provenance"]["backfilled_at"]

      second_summary = travel_to(run_at + 1.day) { described_class.run! }

      expect(OutboxEntry.all.to_a).to match_array(first_rows)
      expect(second_summary[:items]).to include(enqueued: 0, already_present: first_summary[:items][:enqueued])
      expect(item_rows.find { |row| row.external_id == "of-1" }.payload["provenance"]["backfilled_at"]).to eq(backfilled_at)
    end

    it "does not duplicate rows even after a later observation moved the item" do
      travel_to(run_at) { described_class.run! }
      travel_to(run_at + 1.hour) { omnifocus_task.update!(last_observed_at: Time.current) }

      expect { travel_to(run_at + 2.hours) { described_class.run! } }
        .not_to(change { OutboxEntry.where(record_kind: "item").count })
    end
  end

  describe "incomplete records" do
    it "skips items and members without an external id and reports them" do
      GoogleTasks::Task.create!(title: "No external id yet", options: base_options.merge(service_name: "GoogleTasks"))
      collection = SyncCollection.create!(title: "Partially linked", mapping_method: "source_sync_id",
                                          mapping_confidence: "high", mapping_established_at: established_at)
      Omnifocus::Task.create!(title: "Also missing an id", sync_collection: collection, options: base_options)
      asana_task.update!(sync_collection: collection)

      summary = travel_to(run_at) { described_class.run! }

      expect(summary[:items]).to include(candidates: 6, enqueued: 4, skipped_incomplete: 2)
      expect(summary[:items][:by_service]["omnifocus"]).to include(skipped_incomplete: 1)
      expect(summary[:items][:by_service]["google_tasks"]).to include(skipped_incomplete: 1)
      expect(summary[:mappings]).to include(memberships: 2, enqueued: 1, skipped_incomplete: 1)
      expect(item_rows.map(&:external_id)).to contain_exactly("of-1", "asana-9", "gh-42", "gt-7")
    end
  end

  describe "dry runs" do
    it "writes nothing and predicts what a real run would enqueue" do
      collection = SyncCollection.create!(title: "Linked by sync id", mapping_method: "source_sync_id",
                                          mapping_confidence: "high", mapping_established_at: established_at,
                                          sync_items: [omnifocus_task, asana_task])

      summary = travel_to(run_at) { described_class.run!(dry_run: true) }

      expect(OutboxEntry.count).to eq(0)
      expect(summary).to include(dry_run: true)
      expect(summary[:items]).to include(enqueued: 4, already_present: 0)
      expect(summary[:mappings]).to include(enqueued: 2)
      expect(summary[:items][:by_service].keys).to contain_exactly("omnifocus", "asana", "github", "google_tasks")

      travel_to(run_at + 1.minute) { described_class.run! }
      rerun = travel_to(run_at + 2.minutes) { described_class.run!(dry_run: true) }

      expect(rerun[:items]).to include(enqueued: 0, already_present: 4)
      expect(rerun[:mappings]).to include(enqueued: 0, already_present: 2)
      expect(collection.reload.sync_items.count).to eq(2)
    end
  end

  describe "safety" do
    it "never mutates the synced data it reads" do
      collection = SyncCollection.create!(title: "Linked by sync id", mapping_method: "source_sync_id",
                                          mapping_confidence: "high", mapping_established_at: established_at,
                                          sync_items: [omnifocus_task, asana_task])
      items_before = Base::SyncItem.all.map { |item| item.attributes.slice("id", "updated_at", "last_observed_at", "source_metadata", "last_snapshot") }
      collection_before = collection.attributes

      travel_to(run_at) { described_class.run! }
      collection.reload

      expect(Base::SyncItem.all.map { |item| item.attributes.slice("id", "updated_at", "last_observed_at", "source_metadata", "last_snapshot") })
        .to match_array(items_before)
      expect(collection.attributes).to eq(collection_before)
    end
  end
end
