# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:run_at) { Time.zone.parse("2026-10-06T09:00:00Z") }
  let(:base_options) { { services: [], primary: "Omnifocus", tags: [], pretend: false, quiet: true } }

  # Representative records for each of the four services named in #222's
  # acceptance criteria, each carrying the identity shape that service
  # persists: instance-suffixed names for Asana/GitHub, bare names (and so
  # the `:default` instance token) for OmniFocus and Google Tasks.
  let!(:omnifocus_item) do
    Omnifocus::Task.create!(
      options: base_options, title: "Buy milk", external_id: "of-77",
      url: "omnifocus:///task/of-77", last_modified: Time.zone.parse("2026-10-01T08:00:00Z")
    )
  end
  let!(:asana_item) do
    Asana::Task.create!(
      options: base_options.merge(service_name: "Asana:work"), title: "Buy milk", external_id: "asana-1201",
      url: "https://app.asana.com/0/1/1201", last_modified: Time.zone.parse("2026-10-01T09:00:00Z")
    )
  end
  let!(:github_item) do
    Github::Issue.create!(
      options: base_options.merge(service_name: "Github:repo-1"), title: "Release checklist",
      external_id: "issue-42", url: "https://github.com/viamin/task_bridge/issues/42",
      last_modified: Time.zone.parse("2026-10-01T10:00:00Z")
    )
  end
  let!(:google_tasks_item) do
    GoogleTasks::Task.create!(
      options: base_options.merge(service_name: "GoogleTasks"), title: "Buy milk", external_id: "gt-9",
      url: "https://tasks.google.com/gt-9", last_modified: Time.zone.parse("2026-10-01T11:00:00Z")
    )
  end

  # The rake task runs with the default global options (no thread-local
  # override), so DB-loaded items resolve their service context the same way
  # here; rails_helper clears the thread-local between examples.

  def item_rows(external_id = nil)
    scope = OutboxEntry.where(record_kind: "item")
    return scope.to_a if external_id.nil?

    scope.where(external_id:)
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping").to_a
  end

  def assign_collection(collection, *items)
    items.each { |item| item.update!(sync_collection: collection) }
  end

  describe "baseline item snapshots" do
    it "enqueues one item row per service with the permanent identity tokens" do
      travel_to(run_at) { described_class.run! }

      aggregate_failures do
        expect(item_rows.map(&:service_instance)).to contain_exactly(
          "omnifocus:default", "asana:work", "github:repo-1", "google_tasks:default"
        )
        expect(item_rows.map(&:service_type)).to contain_exactly(
          "omnifocus", "asana", "github", "google_tasks"
        )
      end
    end

    it "marks the snapshot as baseline current state, not a change event" do
      travel_to(run_at) { described_class.run! }

      row = item_rows("of-77").first
      expect(row.payload["provenance"]).to eq("detected_by" => "backfill")
      expect(row.payload["backfilled_at"]).to eq(omnifocus_item.last_observed_at.utc.iso8601(6))
      expect(row.payload["observed_at"]).to eq(omnifocus_item.last_observed_at.utc.iso8601(6))
      expect(row.payload["title"]).to eq("Buy milk")
      expect(row.payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-77",
        "source_url" => "omnifocus:///task/of-77"
      )
      expect(row.source_updated_at).to eq(Time.zone.parse("2026-10-01T08:00:00Z"))
      expect(row).to be_pending
    end

    it "uses the item's own observation time in the idempotency key" do
      travel_to(run_at) { described_class.run! }

      row = item_rows("issue-42").first
      expect(row.observed_at).to eq(github_item.last_observed_at)
      expect(row.idempotency_key).to eq(
        "tb:v1:item:github:repo-1:issue-42:snapshot:#{github_item.last_observed_at.utc.iso8601(6)}"
      )
    end

    it "writes no observation rows and no sync_run rows" do
      travel_to(run_at) { described_class.run! }

      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
      expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    end

    it "seeds the live diff baseline only for items without one" do
      existing_baseline = { "version" => 1, "title" => "Existing live baseline" }
      google_tasks_item.update_columns(last_snapshot: existing_baseline)

      travel_to(run_at) { described_class.run! }

      expect(asana_item.reload.last_snapshot).to include("title" => "Buy milk")
      expect(google_tasks_item.reload.last_snapshot).to eq(existing_baseline)
    end

    it "falls back to record timestamps for legacy rows without observations" do
      omnifocus_item.update_columns(last_observed_at: nil, first_observed_at: nil)

      travel_to(run_at) { described_class.run! }

      row = item_rows("of-77").first
      expect(row.observed_at).to eq(omnifocus_item.reload.updated_at)
    end

    it "counts skipped items missing an external id" do
      Omnifocus::Task.create!(options: base_options, title: "No id", external_id: nil)

      summary = travel_to(run_at) { described_class.run! }

      expect(summary.to_h[:skipped_items_by_reason]).to eq("missing_external_id" => 1)
      expect(item_rows.length).to eq(4)
    end
  end

  describe "mapping memberships" do
    let!(:high_collection) do
      collection = SyncCollection.create!(title: "Buy milk")
      assign_collection(collection, omnifocus_item, asana_item)
      collection.update_mapping_provenance!(
        method: "source_sync_id", confidence: "high",
        observed_at: Time.zone.parse("2026-10-02T09:00:00Z")
      )
      collection
    end
    let!(:medium_collection) do
      collection = SyncCollection.create!(title: "Release checklist")
      assign_collection(collection, github_item)
      collection.update_mapping_provenance!(
        method: "title_fallback", confidence: "medium",
        observed_at: Time.zone.parse("2026-10-02T10:00:00Z")
      )
      collection
    end
    let!(:low_collection) do
      collection = SyncCollection.create!(title: "Maybe linked")
      assign_collection(collection, google_tasks_item)
      collection.update_mapping_provenance!(
        method: "manual_backfill", confidence: "low",
        observed_at: Time.zone.parse("2026-10-02T11:00:00Z")
      )
      collection
    end

    it "enqueues confirmed and inferred memberships and withholds low confidence" do
      summary = travel_to(run_at) { described_class.run! }

      aggregate_failures do
        expect(mapping_rows.map(&:external_id)).to contain_exactly("of-77", "asana-1201", "issue-42")
        expect(mapping_rows.select { |row| row.sync_collection_id == high_collection.id }
                           .map { |row| row.payload["mapping_confidence"] }).to all(eq("confirmed"))
        expect(mapping_rows.select { |row| row.sync_collection_id == medium_collection.id }
                           .map { |row| row.payload["mapping_confidence"] }).to all(eq("inferred"))
      end
      expect(summary.to_h[:memberships_by_confidence]).to eq("high" => 2, "medium" => 1)
      expect(summary.to_h[:withheld_memberships_by_confidence]).to eq("low" => 1)
    end

    it "marks mapping rows as baseline and keys them on the collection's mapping observation" do
      travel_to(run_at) { described_class.run! }

      row = mapping_rows.find { |entry| entry.external_id == "issue-42" }
      expect(row.payload["provenance"]).to include("detected_by" => "backfill", "method" => "title_fallback")
      expect(row.payload["backfilled_at"]).to eq("2026-10-02T10:00:00.000000Z")
      expect(row.idempotency_key).to eq(
        "tb:v1:map:sync_collection:#{medium_collection.id}:membership:github:repo-1:issue-42:2026-10-02T10:00:00.000000Z"
      )
    end

    it "counts memberships that cannot be identified as incomplete" do
      unidentified = GoogleTasks::Task.create!(options: base_options.merge(service_name: "GoogleTasks"),
                                               title: "No id", external_id: nil)
      assign_collection(high_collection, unidentified)

      summary = travel_to(run_at) { described_class.run! }

      expect(summary.to_h[:ineligible_memberships]).to eq(1)
      expect(mapping_rows.length).to eq(3)
    end
  end

  describe "idempotency" do
    it "does not duplicate rows or disturb stored baselines on rerun" do
      first_summary = travel_to(run_at) { described_class.run! }
      first_rows = OutboxEntry.all.to_a
      baselines = Base::SyncItem.order(:id).pluck(:id, :last_snapshot)
      omnifocus_item.update_columns(last_modified: Time.zone.parse("2026-10-03T08:00:00Z"))

      second_summary = travel_to(run_at + 1.hour) { described_class.run! }

      expect(OutboxEntry.all.to_a).to match_array(first_rows)
      expect(second_summary.to_h).to eq(first_summary.to_h)
      expect(Base::SyncItem.order(:id).pluck(:id, :last_snapshot)).to eq(baselines)
    end

    it "re-baselines items whose observation moved since the last backfill" do
      travel_to(run_at) { described_class.run! }
      original_observed_at = item_rows("asana-1201").first.observed_at
      later_observed_at = Time.zone.parse("2026-10-06T11:00:00Z")
      asana_item.update_columns(last_observed_at: later_observed_at, last_modified: later_observed_at)

      travel_to(run_at + 3.hours) { described_class.run! }

      expect(item_rows("asana-1201").length).to eq(2)
      expect(item_rows("asana-1201").map(&:observed_at)).to contain_exactly(
        original_observed_at, later_observed_at
      )
    end
  end

  describe "dry run" do
    it "reports what would be written without writing anything" do
      collection = SyncCollection.create!(title: "Buy milk")
      assign_collection(collection, omnifocus_item, asana_item)
      collection.update_mapping_provenance!(method: "source_sync_id", confidence: "high", observed_at: run_at)

      summary = described_class.run!(dry_run: true)

      expect(OutboxEntry.count).to eq(0)
      expect(Base::SyncItem.where.not(last_snapshot: nil)).to be_empty
      expect(summary.to_h[:dry_run]).to be(true)
      expect(summary.items_by_service).to include("omnifocus" => 1, "asana" => 1, "github" => 1, "google_tasks" => 1)
      expect(summary.memberships_by_confidence).to include("high" => 2)
      expect(summary.to_s).to include("dry run — nothing was written")
    end
  end
end
