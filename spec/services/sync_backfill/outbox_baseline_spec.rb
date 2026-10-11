# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:backfilled_at) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:item_created_at) { Time.zone.parse("2026-10-10T09:00:00Z") }
  let(:plain_options) { { services: [], primary: "Omnifocus", tags: [] } }

  # Representative persisted rows for each required service: a plain
  # single-instance service (OmniFocus), an instanced service (Asana:work),
  # and two more provider/task services (GitHub, Google Tasks).
  let!(:omnifocus_item) do
    travel_to(item_created_at) { Omnifocus::Task.create!(title: "Buy milk", external_id: "of-1", options: plain_options) }
  end
  let!(:asana_item) do
    travel_to(item_created_at) do
      Asana::Task.create!(title: "Buy oat milk", external_id: "asana-1",
                          options: plain_options.merge(service_name: "Asana:work"))
    end
  end
  let!(:github_item) do
    travel_to(item_created_at) do
      Github::Issue.create!(
        title: "Fix the sync bug", external_id: "issue-42",
        url: "https://github.com/viamin/task_bridge/issues/42",
        github_issue: { "number" => 42, "state" => "open",
                        "html_url" => "https://github.com/viamin/task_bridge/issues/42",
                        "repository_url" => "https://api.github.com/repos/viamin/task_bridge" },
        options: plain_options
      )
    end
  end
  let!(:google_tasks_item) do
    travel_to(item_created_at) { GoogleTasks::Task.create!(title: "Renew passport", external_id: "gt-1", options: plain_options) }
  end

  # Lazy: a test that builds its own collections must not inherit these.
  let(:confirmed_collection) do
    travel_to(item_created_at) do
      SyncCollection.create!(title: "Fix the sync bug").tap do |collection|
        omnifocus_item.update!(sync_collection: collection, notes: "github_id: issue-42")
        github_item.update!(sync_collection: collection, notes: "omnifocus_id: of-1")
      end
    end
  end
  let(:inferred_collection) do
    travel_to(item_created_at) do
      SyncCollection.create!(title: "Buy oat milk").tap do |collection|
        asana_item.update!(sync_collection: collection)
        google_tasks_item.update!(sync_collection: collection, title: "Buy oat milk")
      end
    end
  end

  before { Thread.current[:global_options] = nil }

  def run_backfill(dry_run: false)
    travel_to(backfilled_at) { described_class.run!(dry_run:, now: backfilled_at) }
  end

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  describe "baseline item snapshots" do
    it "enqueues one marked baseline item row per existing item for each service" do
      run_backfill

      expect(item_rows.count).to eq(4)
      row = item_rows.find_by!(external_id: "of-1")
      expect(row).to have_attributes(
        service_type: "omnifocus",
        service_instance: "omnifocus:default",
        event_type: nil,
        observed_at: item_created_at
      )
      expect(row.idempotency_key).to eq(
        "tb:v1:item:omnifocus:default:of-1:snapshot:#{item_created_at.utc.iso8601(6)}"
      )
      expect(row.payload).to include(
        "contract_version" => 1,
        "entity_type" => "task",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false,
        "item_key" => "omnifocus:of-1"
      )
      expect(row.payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-1",
        "source_url" => "omnifocus:///task/of-1"
      )
      # Baseline rows are marked as initial observations, never as
      # historical change events (#222 clarification).
      expect(row.payload["provenance"]).to eq(
        "detected_by" => "backfill", "backfilled_at" => backfilled_at.utc.iso8601(6)
      )
      expect(row.payload["source_metadata"]).to eq({})
    end

    it "uses the configured instance name for instanced services" do
      run_backfill

      row = item_rows.find_by!(external_id: "asana-1")
      expect(row.service_instance).to eq("asana:work")
      expect(row.idempotency_key).to start_with("tb:v1:item:asana:work:asana-1:snapshot:")
      expect(row.payload["source"]["service_instance"]).to eq("asana:work")
    end

    it "snapshots GitHub and Google Tasks rows loaded from the database" do
      run_backfill

      github_row = item_rows.find_by!(service_type: "github")
      expect(github_row.payload["title"]).to eq("Fix the sync bug")
      expect(github_row.payload["source"]["source_url"]).to eq("https://github.com/viamin/task_bridge/issues/42")

      google_row = item_rows.find_by!(service_type: "google_tasks")
      expect(google_row.payload["status"]).to eq("open")
      expect(google_row.idempotency_key).to start_with("tb:v1:item:google_tasks:default:gt-1:snapshot:")
    end

    it "emits no observation or sync_run rows" do
      run_backfill

      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
      expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    end

    it "records the published snapshot as the live pipeline's diff baseline" do
      run_backfill

      expect(omnifocus_item.reload.last_snapshot).to include(
        "title" => "Buy milk", "status" => "open", "item_key" => "omnifocus:of-1"
      )
      expect(omnifocus_item.last_observed_at).to eq(item_created_at)
    end

    it "skips items the live pipeline already observed" do
      google_tasks_item.update_column(:last_snapshot, { "title" => "Renew passport" })

      report = run_backfill

      expect(item_rows.count).to eq(3)
      expect(report[:items]).to include(enqueued: 3, already_observed: 1)
      expect(item_rows.map(&:external_id)).not_to include("gt-1")
    end
  end

  describe "mapping rows" do
    it "publishes id-derived mappings as confirmed and title-derived ones as inferred" do
      confirmed_collection
      inferred_collection

      report = run_backfill

      expect(mapping_rows.count).to eq(4)
      confirmed = mapping_rows.find_by!(external_id: "of-1")
      expect(confirmed.sync_collection_id).to eq(confirmed_collection.id)
      expect(confirmed.payload).to include(
        "mapping_confidence" => "confirmed",
        "mapping_source" => "sync_id_note",
        "membership_role" => "member"
      )
      expect(confirmed.payload["provenance"]).to include(
        "method" => "source_sync_id", "confidence" => "high",
        "detected_by" => "backfill", "backfilled_at" => backfilled_at.utc.iso8601(6)
      )

      inferred = mapping_rows.find_by!(external_id: "gt-1")
      expect(inferred.sync_collection_id).to eq(inferred_collection.id)
      expect(inferred.payload).to include("mapping_confidence" => "inferred", "mapping_source" => "title_match")
      expect(inferred.payload["provenance"]).to include("method" => "title_fallback", "confidence" => "medium")

      expect(report[:by_confidence]).to eq("confirmed" => 2, "inferred" => 2)
    end

    it "withholds low-confidence memberships from publication but keeps them countable" do
      low_collection = SyncCollection.create!(title: "Legacy member")
      low_collection.update_columns(mapping_method: "manual_backfill", mapping_confidence: "low")
      omnifocus_item.update!(sync_collection: low_collection)

      report = run_backfill

      expect(mapping_rows).to be_empty
      expect(mapping_rows.where(sync_collection_id: low_collection.id)).to be_empty
      expect(report[:mappings]).to include(withheld: 1)
      expect(report[:by_confidence]).to eq("tentative" => 1)
      expect(report[:by_service]["omnifocus"]).to include(items: 1, mappings: 0, withheld: 1)
    end

    it "includes membership on publishable item snapshots and omits it for withheld ones" do
      inferred_collection
      low_collection = SyncCollection.create!(title: "Legacy member")
      low_collection.update_columns(mapping_method: "manual_backfill", mapping_confidence: "low")
      omnifocus_item.update!(sync_collection: low_collection)

      run_backfill

      published = item_rows.find_by!(external_id: "gt-1")
      expect(published.payload["sync_collection"]).to include(
        "sync_collection_id" => inferred_collection.id,
        "mapping_confidence" => "inferred",
        "mapping_source" => "title_match"
      )
      withheld = item_rows.find_by!(external_id: "of-1")
      expect(withheld.payload["sync_collection"]).to be_nil
      expect(withheld.payload["sync_collection_id"]).to eq(low_collection.id)
    end
  end

  describe "idempotency" do
    it "running twice enqueues no duplicate rows and reports everything as covered" do
      run_backfill
      first_counts = OutboxEntry.count

      second_report = run_backfill

      expect(OutboxEntry.count).to eq(first_counts)
      expect(second_report[:items]).to include(enqueued: 0, already_observed: 4)
      expect(second_report[:mappings]).to include(enqueued: 0)
    end

    it "reuses mapping rows by their deterministic keys" do
      SyncCollection.create!(title: "Pair").tap do |collection|
        omnifocus_item.update!(sync_collection: collection, notes: "github_id: issue-42")
        github_item.update!(sync_collection: collection, notes: "omnifocus_id: of-1")
      end
      run_backfill
      keys = mapping_rows.order(:idempotency_key).pluck(:idempotency_key)

      report = run_backfill

      expect(mapping_rows.order(:idempotency_key).pluck(:idempotency_key)).to eq(keys)
      expect(report[:mappings]).to include(enqueued: 0, existing: 2)
    end
  end

  describe "skipped and incomplete records" do
    it "counts items and memberships that cannot be identified" do
      incomplete = travel_to(item_created_at) do
        Asana::Task.create!(title: "No external id", external_id: nil, options: plain_options)
      end
      insert_typeless_row(title: "Legacy row")
      collection = SyncCollection.create!(title: "Incomplete member")
      collection.update_columns(mapping_method: "manual_backfill", mapping_confidence: "low")
      incomplete.update!(sync_collection: collection)

      report = run_backfill

      expect(report[:items][:skipped]).to eq("missing_external_id" => 1, "missing_sti_type" => 1)
      expect(report[:mappings][:skipped]).to eq("missing_external_id" => 1)
      expect(item_rows.map(&:external_id)).not_to include(nil)
    end
  end

  describe "dry run" do
    it "writes nothing and reports the counts a real run would produce" do
      SyncCollection.create!(title: "Pair").tap do |collection|
        omnifocus_item.update!(sync_collection: collection, notes: "github_id: issue-42")
        github_item.update!(sync_collection: collection, notes: "omnifocus_id: of-1")
      end

      dry_report = run_backfill(dry_run: true)

      expect(OutboxEntry.count).to eq(0)
      expect(Base::SyncItem.where.not(last_snapshot: nil)).to be_empty
      expect(dry_report[:dry_run]).to be(true)
      expect(dry_report[:items]).to include(enqueued: 4)
      expect(dry_report[:mappings]).to include(enqueued: 2)

      real_report = run_backfill
      expect(real_report[:items][:enqueued]).to eq(dry_report[:items][:enqueued])
      expect(real_report[:mappings][:enqueued]).to eq(dry_report[:mappings][:enqueued])
    end

    it "infers mapping confidence read-only so withheld counts stay accurate" do
      SyncCollection.create!(title: "Unbackfilled pair").tap do |collection|
        omnifocus_item.update!(sync_collection: collection, notes: "github_id: issue-42")
        github_item.update!(sync_collection: collection, notes: "omnifocus_id: of-1")
      end

      dry_report = run_backfill(dry_run: true)

      # Source-provenance backfill has not run (dry run writes nothing), so
      # the collection's high-confidence inference is computed read-only.
      expect(dry_report[:mappings]).to include(enqueued: 2)
      expect(dry_report[:by_confidence]).to include("confirmed" => 2)
      expect(SyncCollection.last.mapping_method).to be_nil
    end
  end

  describe "the report" do
    it "renders an operator-facing summary" do
      report = run_backfill(dry_run: true)

      rendered = described_class::Summary.render(report)
      expect(rendered).to include("DRY RUN")
      expect(rendered).to include("Items: 4 baseline snapshot rows would be enqueued")
      expect(rendered).to include("By service:")
      expect(rendered).to include("omnifocus: 1 items")
      expect(rendered).to include("By confidence: none")
    end
  end

  # A row without an STI type has no provider; it can only be inserted
  # behind ActiveRecord's back (callbacks would raise without a source
  # service name and notes).
  def insert_typeless_row(title:)
    now = Time.current.utc.iso8601(6)
    Base::SyncItem.connection.exec_insert(
      "INSERT INTO sync_items (title, notes, source_service_name, type, created_at, updated_at) " \
      "VALUES ('#{title}', 'legacy note', 'Omnifocus', NULL, '#{now}', '#{now}')", nil, nil
    )
  end
end
