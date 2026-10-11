# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.parse("2026-10-11T09:00:00Z") }
  let(:observed_at) { Time.zone.parse("2026-10-10T08:00:00Z") }

  before do
    travel_to(now) do
      asana_item && omnifocus_item && github_item && google_tasks_item && incomplete_item
    end
  end

  # One representative per required service: an instanced provider task,
  # a single-instance primary task, a provider issue, and another
  # single-instance task service.
  let!(:asana_item) do
    Asana::Task.create!(
      title: "Buy milk", external_id: "asana-1", source_service_name: "Asana:work",
      notes: "omnifocus_id: of-1", url: "https://app.asana.com/0/1/asana-1",
      sync_collection: confirmed_collection, last_modified: observed_at, updated_at: observed_at,
      created_at: observed_at
    )
  end
  let!(:omnifocus_item) do
    Omnifocus::Task.create!(
      title: "Buy milk", external_id: "of-1", source_service_name: "Omnifocus",
      notes: "asana_work_id: asana-1", url: "omnifocus:///task/of-1",
      sync_collection: confirmed_collection, last_modified: observed_at, updated_at: observed_at,
      created_at: observed_at
    )
  end
  let!(:github_item) do
    Github::Issue.create!(
      title: "Release checklist", external_id: "issue-42", source_service_name: "Github:repo-1",
      url: "https://github.com/viamin/task_bridge/issues/42",
      sync_collection: title_matched_collection, updated_at: observed_at, created_at: observed_at
    )
  end
  let!(:google_tasks_item) do
    GoogleTasks::Task.create!(
      title: "Buy oat milk", external_id: "gt-7", source_service_name: "GoogleTasks",
      updated_at: observed_at, created_at: observed_at
    )
  end
  let!(:incomplete_item) do
    Github::Issue.create!(
      title: "No external id", external_id: "", source_service_name: "Github:repo-1",
      updated_at: observed_at, created_at: observed_at
    )
  end

  # ID-derived mapping: notes cross-reference each other's external ids.
  let!(:confirmed_collection) do
    SyncCollection.create!(title: "Buy milk", mapping_method: "source_sync_id", mapping_confidence: "high",
                           mapping_last_observed_at: observed_at, mapping_established_at: observed_at)
  end
  # Title-derived mapping: same titles, no sync-id evidence.
  let!(:title_matched_collection) do
    SyncCollection.create!(title: "Release checklist", mapping_method: "title_fallback", mapping_confidence: "medium",
                           mapping_last_observed_at: observed_at, mapping_established_at: observed_at)
  end
  # Low-confidence mapping: withheld from publication.
  let!(:low_confidence_collection) do
    SyncCollection.create!(title: "Stale guess", mapping_method: "manual_backfill", mapping_confidence: "low",
                           mapping_last_observed_at: observed_at, mapping_established_at: observed_at)
  end
  let!(:omnifocus_low_item) do
    Omnifocus::Task.create!(
      title: "Stale guess", external_id: "of-99", source_service_name: "Omnifocus",
      sync_collection: low_confidence_collection, updated_at: observed_at, created_at: observed_at
    )
  end
  let!(:google_tasks_low_item) do
    GoogleTasks::Task.create!(
      title: "Stale guess", external_id: "gt-99", source_service_name: "GoogleTasks",
      sync_collection: low_confidence_collection, updated_at: observed_at, created_at: observed_at
    )
  end

  describe "#run!" do
    it "enqueues one baseline item snapshot per identifiable sync item" do
      summary = described_class.run!(now:)

      item_rows = OutboxEntry.where(record_kind: "item")
      expect(item_rows.count).to eq(6)
      expect(summary[:items]).to include(
        candidates: 7, enqueued: 6, already_present: 0, skipped_incomplete: 1
      )
      expect(summary[:items][:by_service]).to eq(
        "asana" => 1, "omnifocus" => 2, "github" => 1, "google_tasks" => 2
      )
    end

    it "identifies every representative service correctly" do
      described_class.run!(now:)

      identities = OutboxEntry.where(record_kind: "item").index_by(&:external_id)
      expect(identities["asana-1"]).to have_attributes(
        service_type: "asana", service_instance: "asana:work",
        idempotency_key: "tb:v1:item:asana:work:asana-1:snapshot:#{now.utc.iso8601(6)}"
      )
      expect(identities["of-1"]).to have_attributes(service_type: "omnifocus", service_instance: "omnifocus:default")
      expect(identities["issue-42"]).to have_attributes(service_type: "github", service_instance: "github:repo-1")
      expect(identities["gt-7"]).to have_attributes(service_type: "google_tasks", service_instance: "google_tasks:default")
    end

    it "publishes item snapshots as baseline state, not change events" do
      described_class.run!(now:)

      row = OutboxEntry.find_by(record_kind: "item", external_id: "asana-1")
      expect(row.payload).to include(
        "contract_version" => 1,
        "item_key" => "asana_work:asana-1",
        "entity_type" => "task",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false,
        "observed_at" => now.utc.iso8601(6),
        "provenance" => {
          "detected_by" => "backfill", "backfilled_at" => now.utc.iso8601(6)
        }
      )
      expect(row.payload["source"]).to include(
        "service_type" => "asana",
        "service_instance" => "asana:work",
        "external_id" => "asana-1",
        "source_url" => "https://app.asana.com/0/1/asana-1"
      )
      # The backfill never pretends to be historical change history.
      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
      expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    end

    it "publishes confirmed and inferred mappings and withholds low-confidence ones" do
      summary = described_class.run!(now:)

      mapping_rows = OutboxEntry.where(record_kind: "mapping")
      # high (source_sync_id) -> confirmed, medium (title_fallback) -> inferred
      expect(mapping_rows.map { |row| [row.sync_collection_id, row.payload["mapping_confidence"]] })
        .to contain_exactly(
          [confirmed_collection.id, "confirmed"],
          [confirmed_collection.id, "confirmed"],
          [title_matched_collection.id, "inferred"]
        )
      expect(mapping_rows.where(sync_collection_id: low_confidence_collection.id)).to be_empty
      expect(summary[:mappings]).to include(
        collections: 3, enqueued: 3, already_present: 0, withheld: 2
      )
      expect(summary[:mappings][:by_confidence]).to eq("confirmed" => 2, "inferred" => 1)
      expect(summary[:mappings][:withheld_collections]).to eq([[low_confidence_collection.id, "Stale guess"]])
    end

    it "marks mapping rows as backfilled observations" do
      described_class.run!(now:)

      row = OutboxEntry.find_by(record_kind: "mapping", external_id: "issue-42")
      expect(row.observed_at).to eq(observed_at)
      expect(row.idempotency_key).to eq(
        "tb:v1:map:sync_collection:#{title_matched_collection.id}:membership:github:repo-1:issue-42:#{observed_at.utc.iso8601(6)}"
      )
      expect(row.payload["provenance"]).to include(
        "method" => "title_fallback",
        "confidence" => "medium",
        "detected_by" => "backfill",
        "backfilled_at" => now.utc.iso8601(6)
      )
    end

    it "is idempotent: rerunning enqueues nothing new and leaves rows untouched" do
      described_class.run!(now:)
      first_run_attributes = OutboxEntry.all.to_h { |row| [row.id, row.attributes] }
      expect(first_run_attributes).not_to be_empty

      summary = nil
      travel_to(now + 1.hour) { summary = described_class.run!(now: now + 1.hour) }

      expect(OutboxEntry.count).to eq(first_run_attributes.count)
      expect(summary[:items]).to include(enqueued: 0, already_present: 6)
      expect(summary[:mappings]).to include(enqueued: 0, already_present: 3)
      first_run_attributes.each do |id, attributes|
        expect(OutboxEntry.find(id).attributes).to eq(attributes)
      end
    end

    it "does not re-enqueue delivered rows or reset their delivery state" do
      described_class.run!(now:)
      OutboxEntry.find_each { |row| row.mark_delivered!(at: now) }

      described_class.run!(now:)

      expect(OutboxEntry.where(status: "delivered").count).to eq(OutboxEntry.count)
    end

    it "does not advance the live diff baseline stored on items" do
      described_class.run!(now:)

      expect(Base::SyncItem.where.not(last_snapshot: nil)).to be_empty
    end

    it "only touches local tables and never instantiates external services" do
      allow(Base::Service).to receive(:resolve_service_class).and_raise("external service must not be contacted")

      expect { described_class.run!(now:) }.not_to raise_error
    end
  end

  describe "dry run" do
    it "writes nothing and summarizes what would be enqueued" do
      summary = nil
      travel_to(now) { summary = described_class.run!(dry_run: true, now:) }

      expect(OutboxEntry.count).to eq(0)
      expect(summary[:dry_run]).to be(true)
      expect(summary[:items]).to include(candidates: 7, enqueued: 6, already_present: 0, skipped_incomplete: 1)
      expect(summary[:mappings]).to include(enqueued: 3, withheld: 2)
      expect(summary[:mappings][:by_confidence]).to eq("confirmed" => 2, "inferred" => 1)
    end

    it "reports rows that a previous run already enqueued" do
      described_class.run!(now:)

      summary = described_class.run!(dry_run: true, now:)

      expect(summary[:items]).to include(enqueued: 0, already_present: 6)
      expect(summary[:mappings]).to include(enqueued: 0, already_present: 3)
      expect(OutboxEntry.count).to eq(9)
    end
  end

  describe ".render" do
    it "summarizes counts by service, confidence, and withheld collections" do
      summary = described_class.run!(now:)

      report = described_class.render(summary)

      expect(report).to include("TaskBridge outbox baseline backfill")
      expect(report).to include("Items: 7 candidates, 6 enqueued, 0 already present, 1 skipped (missing external id)")
      expect(report).to include("asana=1, github=1, google_tasks=2, omnifocus=2")
      expect(report).to include("Mappings: 3 collections, 3 enqueued, 0 already present, 2 withheld (low confidence)")
      expect(report).to include("By confidence: confirmed=2, inferred=1")
      expect(report).to include(%(##{low_confidence_collection.id} "Stale guess"))
    end

    it "marks dry-run reports and empty withholding explicitly" do
      report = described_class.render(described_class.run!(dry_run: true, now:))

      expect(report).to include("(dry run — nothing written)")
    end
  end
end
