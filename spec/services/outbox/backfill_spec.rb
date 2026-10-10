# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::Backfill do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.parse("2026-10-10T09:00:00Z") }
  let(:base_options) { { services: [], primary: "Omnifocus", tags: [] } }
  let(:confirmed_collection) do
    SyncCollection.create!(
      title: "Ship the release",
      mapping_method: "source_sync_id",
      mapping_confidence: "high",
      mapping_metadata: { "note_key" => "asana_work_id" }
    )
  end
  let(:inferred_collection) do
    SyncCollection.create!(
      title: "Fix login bug",
      mapping_method: "title_fallback",
      mapping_confidence: "medium",
      mapping_metadata: { "matched_by" => "title" }
    )
  end
  let(:withheld_collection) do
    SyncCollection.create!(
      title: "Maybe related",
      mapping_method: "manual_backfill",
      mapping_confidence: "low",
      mapping_metadata: {}
    )
  end
  let(:omnifocus_item) do
    Omnifocus::Task.create!(
      options: base_options.merge(service_name: "Omnifocus"),
      title: "Ship the release",
      external_id: "of-1",
      notes: "asana_work_id: asana-123",
      sync_collection: confirmed_collection,
      url: "omnifocus:///task/of-1"
    )
  end
  let(:asana_item) do
    Asana::Task.create!(
      options: base_options.merge(service_name: "Asana:work"),
      title: "Ship the release",
      external_id: "asana-123",
      sync_collection: confirmed_collection,
      url: "https://app.asana.com/0/1/asana-123"
    )
  end
  let(:github_item) do
    Github::Issue.create!(
      options: base_options.merge(service_name: "Github:repo-1"),
      title: "Fix login bug",
      external_id: "issue-42",
      status: "open",
      sync_collection: inferred_collection,
      url: "https://github.com/repo-1/issues/42"
    )
  end
  let(:google_tasks_item) do
    GoogleTasks::Task.create!(
      options: base_options.merge(service_name: "GoogleTasks"),
      title: "Maybe related",
      external_id: "gt-9",
      sync_collection: withheld_collection
    )
  end

  before do
    confirmed_collection
    inferred_collection
    withheld_collection
    omnifocus_item
    asana_item
    github_item
    google_tasks_item
  end

  describe ".run!" do
    it "enqueues one baseline item snapshot per existing item across services" do
      travel_to(now) { described_class.run! }

      rows = OutboxEntry.where(record_kind: "item").index_by(&:service_instance)
      expect(rows.keys).to contain_exactly("omnifocus:default", "asana:work", "github:repo-1", "google_tasks:default")
      expect(rows["omnifocus:default"]).to have_attributes(
        external_id: "of-1",
        service_type: "omnifocus",
        sync_collection_id: confirmed_collection.id,
        observed_at: omnifocus_item.reload.last_observed_at,
        source_updated_at: omnifocus_item.source_updated_at
      )
    end

    it "marks item snapshots as baseline current state, not history" do
      travel_to(now) { described_class.run! }

      row = OutboxEntry.find_by(record_kind: "item", service_instance: "omnifocus:default")
      observed_at = omnifocus_item.reload.last_observed_at.utc.iso8601(6)
      expect(row.payload).to include(
        "item_key" => "omnifocus:of-1",
        "entity_type" => "task",
        "title" => "Ship the release",
        "status" => "open",
        "is_deleted" => false,
        "observed_at" => observed_at,
        "provenance" => {
          "detected_by" => "backfill",
          "backfilled_at" => now.utc.iso8601(6)
        }
      )
      expect(row.payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-1",
        "source_url" => "omnifocus:///task/of-1"
      )
      expect(row.payload["source_metadata"]).to eq({})
      expect(row.payload).not_to include("version", "metadata")
      expect(row.idempotency_key).to eq("tb:v1:item:omnifocus:default:of-1:snapshot:#{observed_at}")
    end

    it "writes no observation or sync_run rows and leaves the live diff baseline untouched" do
      travel_to(now) { described_class.run! }

      expect(OutboxEntry.where(record_kind: %w[observation sync_run])).to be_empty
      expect(omnifocus_item.reload.last_snapshot).to be_nil
    end

    it "backfills provenance first so legacy rows can be baselined" do
      legacy = Omnifocus::Task.create!(
        options: base_options.merge(service_name: "Omnifocus"),
        title: "Legacy item",
        external_id: "of-legacy"
      )
      legacy.update_columns(
        source_service_name: nil,
        source_service_instance: nil,
        source_service_type: nil,
        source_external_id: nil,
        first_observed_at: nil,
        last_observed_at: nil
      )

      travel_to(now) { described_class.run! }

      expect(legacy.reload.source_service_name).to eq("Omnifocus")
      expect(OutboxEntry.find_by(record_kind: "item", external_id: "of-legacy")).to be_present
    end

    it "enqueues mapping rows for confirmed and inferred memberships only" do
      travel_to(now) { described_class.run! }

      rows = OutboxEntry.where(record_kind: "mapping")
      expect(rows.map(&:service_instance)).to contain_exactly(
        "omnifocus:default", "asana:work", "github:repo-1"
      )
      confirmed = rows.find { |row| row.external_id == "asana-123" }
      expect(confirmed.payload).to include(
        "mapping_type" => "representation_membership",
        "membership_role" => "member",
        "mapping_confidence" => "confirmed",
        "mapping_source" => "sync_id_note"
      )
      expect(confirmed.payload["member"]).to include(
        "item_key" => "asana_work:asana-123",
        "service_type" => "asana",
        "service_instance" => "asana:work",
        "external_id" => "asana-123"
      )
      expect(confirmed.payload["sync_collection"]).to include(
        "sync_collection_id" => confirmed_collection.id,
        "title" => "Ship the release"
      )
      expect(confirmed.payload["provenance"]).to include(
        "detected_by" => "backfill",
        "backfilled_at" => now.utc.iso8601(6),
        "method" => "source_sync_id",
        "confidence" => "high"
      )

      inferred = rows.find { |row| row.external_id == "issue-42" }
      expect(inferred.payload).to include("mapping_confidence" => "inferred", "mapping_source" => "title_match")
    end

    it "withholds low-confidence mappings from publication but keeps them countable" do
      summary = nil
      travel_to(now) { summary = described_class.run! }

      expect(OutboxEntry.where(record_kind: "mapping", external_id: "gt-9")).to be_empty
      expect(summary[:mappings][:withheld]).to eq(1)
      expect(summary[:mappings][:by_confidence]).to eq("high" => 2, "medium" => 1, "low" => 1)
      expect(summary[:skipped_reasons]).to include("memberships_withheld_low_confidence" => 1)
    end

    it "omits the sync_collection block from item snapshots of withheld mappings" do
      travel_to(now) { described_class.run! }

      row = OutboxEntry.find_by(record_kind: "item", external_id: "gt-9")
      expect(row.payload).not_to have_key("sync_collection")

      member_row = OutboxEntry.find_by(record_kind: "item", external_id: "issue-42")
      expect(member_row.payload["sync_collection"]).to include(
        "sync_collection_id" => inferred_collection.id,
        "mapping_confidence" => "inferred",
        "mapping_source" => "title_match"
      )
    end

    it "is idempotent across reruns" do
      travel_to(now) { described_class.run! }
      first_rows = OutboxEntry.all.to_a
      first_state = first_rows.map { |row| [row.idempotency_key, row.payload, row.updated_at] }

      travel_to(now + 1.hour) { described_class.run! }

      expect(OutboxEntry.count).to eq(first_rows.length)
      expect(OutboxEntry.all.to_a.map { |row| [row.idempotency_key, row.payload, row.updated_at] }).to eq(first_state)
    end

    it "summarizes counts by service and reports skipped records" do
      Omnifocus::Task.create!(
        options: base_options.merge(service_name: "Omnifocus"),
        title: "No external id",
        external_id: nil
      )
      summary = nil
      travel_to(now) { summary = described_class.run! }

      expect(summary[:status]).to eq("completed")
      expect(summary[:items]).to include(considered: 5, enqueued: 4, skipped: 1, dropped: 0)
      expect(summary[:mappings]).to include(memberships: 4, enqueued: 3, withheld: 1, skipped: 0, dropped: 0)
      expect(summary[:items][:by_service]["omnifocus"]).to include(enqueued: 1, skipped: 1)
      expect(summary[:skipped_reasons]).to include("items_missing_external_id" => 1)
    end

    it "counts memberships of collections without mapping confidence as incomplete" do
      unclassified = SyncCollection.create!(title: "Unclassified", mapping_method: "source_sync_id")
      GoogleTasks::Task.create!(
        options: base_options.merge(service_name: "GoogleTasks"),
        title: "Unclassified member",
        external_id: "gt-99",
        sync_collection: unclassified
      )

      summary = nil
      travel_to(now) { summary = described_class.run! }

      expect(OutboxEntry.where(record_kind: "mapping", external_id: "gt-99")).to be_empty
      expect(summary[:mappings][:skipped]).to eq(1)
      expect(summary[:skipped_reasons]).to include("memberships_missing_mapping_confidence" => 1)
      expect(summary[:mappings][:by_confidence]).to include("unknown" => 1)
    end
  end

  describe ".run! with dry_run" do
    it "writes nothing, skips the provenance backfill, and still reports counts" do
      legacy = Omnifocus::Task.create!(
        options: base_options.merge(service_name: "Omnifocus"),
        title: "Legacy item",
        external_id: "of-legacy"
      )
      legacy.update_columns(last_observed_at: nil)

      summary = travel_to(now) { described_class.run!(dry_run: true) }

      expect(OutboxEntry.count).to eq(0)
      expect(legacy.reload.last_observed_at).to be_nil
      expect(summary[:status]).to eq("dry_run")
      expect(summary[:items]).to include(considered: 5, enqueued: 5, skipped: 0, dropped: 0)
      expect(summary[:mappings]).to include(memberships: 4, enqueued: 3, withheld: 1, skipped: 0, dropped: 0)
      expect(summary[:items][:by_service].keys).to contain_exactly("omnifocus", "asana_work", "github_repo_1", "google_tasks")
    end
  end
end
