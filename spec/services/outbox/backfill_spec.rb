# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::Backfill do
  include ActiveSupport::Testing::TimeHelpers

  let(:run_at) { Time.zone.parse("2026-10-11T09:00:00Z") }
  let(:observed_at) { Time.zone.parse("2026-10-10T10:00:00Z") }
  let(:confirmed_collection) do
    SyncCollection.create!(
      title: "Ship the release",
      mapping_method: "source_sync_id",
      mapping_confidence: "high",
      mapping_last_observed_at: observed_at
    )
  end
  let(:inferred_collection) do
    SyncCollection.create!(
      title: "Review the checklist",
      mapping_method: "title_fallback",
      mapping_confidence: "medium",
      mapping_last_observed_at: observed_at
    )
  end
  let(:tentative_collection) do
    SyncCollection.create!(
      title: "Maybe linked",
      mapping_method: "manual_backfill",
      mapping_confidence: "low",
      mapping_last_observed_at: observed_at
    )
  end
  # A method without a confidence classification never becomes publishable.
  let(:unclassified_collection) do
    SyncCollection.create!(title: "Unclassified", mapping_method: "manual_backfill")
  end

  # Representative records across the services named in #222's acceptance
  # criteria, persisted with the columns the backfill reads (STI type,
  # external_id, url, last_modified, parsed notes, instance names).
  let(:omnifocus_task) do
    Omnifocus::Task.create!(
      title: "Ship the release",
      external_id: "of-77",
      url: "omnifocus:///task/of-77",
      notes: "asana_work_id: asana-123",
      last_modified: observed_at,
      sync_collection: confirmed_collection
    )
  end
  let(:asana_task) do
    Asana::Task.create!(
      title: "Ship the release",
      external_id: "asana-123",
      source_service_name: "Asana:work",
      notes: "omnifocus_id: of-77",
      last_modified: observed_at,
      sync_collection: confirmed_collection
    )
  end
  let(:github_issue) do
    Github::Issue.create!(
      title: "Review the checklist",
      external_id: "issue-42",
      last_modified: observed_at,
      sync_collection: inferred_collection
    )
  end
  let(:google_task) do
    GoogleTasks::Task.create!(
      title: "Review the checklist",
      external_id: "gt-task-9",
      last_modified: observed_at,
      sync_collection: inferred_collection
    )
  end

  # capture_source_identity stamps last_observed_at with Time.current on
  # save, so records are created inside the observation window they claim.
  before do
    travel_to(observed_at) do
      confirmed_collection
      inferred_collection
      tentative_collection
      omnifocus_task
      asana_task
      github_issue
      google_task
    end
  end

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  def run_backfill(**)
    travel_to(run_at) { described_class.run!(**) }
  end

  describe "baseline item snapshots" do
    it "enqueues one baseline item row per existing sync item with the default instance token" do
      summary = run_backfill

      expect(item_rows.count).to eq(4)
      row = item_rows.find { |entry| entry.service_type == "omnifocus" }
      expect(row).to have_attributes(
        external_id: "of-77",
        service_instance: "omnifocus:default",
        sync_collection_id: confirmed_collection.id,
        observed_at: observed_at,
        status: "pending"
      )
      expect(row.idempotency_key).to eq("tb:v1:item:omnifocus:default:of-77:snapshot:2026-10-10T10:00:00.000000Z")

      expect(item_rows.to_h { |entry| [entry.service_type, entry.service_instance] })
        .to include("asana" => "asana:work", "github" => "github:default", "google_tasks" => "google_tasks:default")
      expect(summary[:items][:enqueued_by_service])
        .to eq("omnifocus" => 1, "asana" => 1, "github" => 1, "google_tasks" => 1)
    end

    it "marks the snapshot as a baseline observation rather than a change event" do
      run_backfill

      payload = item_rows.find { |entry| entry.external_id == "of-77" }.payload
      expect(payload).to include(
        "contract_version" => 1,
        "entity_type" => "task",
        "title" => "Ship the release",
        "status" => "open",
        "is_deleted" => false,
        "observed_at" => "2026-10-10T10:00:00.000000Z"
      )
      expect(payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-77",
        "source_url" => "omnifocus:///task/of-77"
      )
      expect(payload["provenance"]).to include(
        "detected_by" => "backfill",
        "backfilled_at" => "2026-10-11T09:00:00.000000Z"
      )
      # No observation or sync-run rows: a baseline is not a historical
      # change event, and per-run timestamps are not reliable (#222).
      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
      expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    end

    it "renders backfilled rows into the contract's items array unchanged" do
      run_backfill

      batch = Outbox::WebPublisher::Batch.new(item_rows.order(:id).to_a, now: run_at)
      expect(batch.body[:items].length).to eq(4)
      expect(batch.body[:items]).to all(include("idempotency_key" => start_with("tb:v1:item:"), "contract_version" => 1))
    end
  end

  describe "mapping rows" do
    it "enqueues confirmed and inferred memberships with translated confidence" do
      run_backfill

      expect(mapping_rows.count).to eq(4)
      confirmed = mapping_rows.where(sync_collection_id: confirmed_collection.id)
      expect(confirmed.map { |row| row.payload["mapping_confidence"] }).to all(eq("confirmed"))
      expect(confirmed.map { |row| row.payload["mapping_source"] }).to all(eq("sync_id_note"))
      expect(confirmed.map(&:external_id)).to contain_exactly("of-77", "asana-123")
      inferred = mapping_rows.where(sync_collection_id: inferred_collection.id)
      expect(inferred.map { |row| row.payload["mapping_confidence"] }).to all(eq("inferred"))
      expect(inferred.map { |row| row.payload["mapping_source"] }).to all(eq("title_match"))
    end

    it "withholds low-confidence memberships from publication but keeps their item snapshots" do
      tentative_collection
      travel_to(observed_at) do
        Omnifocus::Task.create!(title: "Maybe linked", external_id: "of-88", sync_collection: tentative_collection)
        Asana::Task.create!(title: "Maybe linked", external_id: "asana-999",
                            source_service_name: "Asana:work", sync_collection: tentative_collection)
      end

      summary = run_backfill

      expect(mapping_rows.where(sync_collection_id: tentative_collection.id)).to be_empty
      expect(summary[:mappings][:withheld_by_confidence]).to eq("tentative" => 2)
      expect(item_rows.map(&:external_id)).to include("of-88", "asana-999")
    end

    it "withholds memberships whose confidence cannot be classified" do
      unclassified_collection
      travel_to(observed_at) do
        Omnifocus::Task.create!(title: "Unclassified", external_id: "of-90", sync_collection: unclassified_collection)
        Asana::Task.create!(title: "Unclassified", external_id: "asna-901",
                            source_service_name: "Asana:work", sync_collection: unclassified_collection)
      end

      summary = run_backfill

      expect(mapping_rows.where(sync_collection_id: unclassified_collection.id)).to be_empty
      expect(summary[:mappings][:withheld_by_confidence]).to eq("tentative" => 2)
    end

    it "ignores collection members that cannot be identified" do
      asana_task.update_columns(external_id: nil, source_external_id: nil)

      summary = run_backfill

      expect(mapping_rows.where(external_id: "asana-123")).to be_empty
      expect(summary[:mappings][:enqueued_by_confidence]).to eq("confirmed" => 1, "inferred" => 2)
      expect(summary[:items][:skipped_by_reason]).to eq("missing_external_id" => 1)
    end
  end

  describe "idempotency" do
    it "re-running writes no duplicate rows and reports identical counts" do
      first_summary = run_backfill
      first_keys = OutboxEntry.order(:id).map(&:idempotency_key)

      second_summary = travel_to(run_at + 1.hour) { described_class.run! }

      expect(OutboxEntry.order(:id).map(&:idempotency_key)).to eq(first_keys)
      expect(second_summary).to eq(first_summary)
    end

    it "keeps stored payloads immutable across reruns" do
      run_backfill
      stored_payload = item_rows.find { |entry| entry.external_id == "of-77" }.payload

      travel_to(run_at + 1.day) { described_class.run! }

      expect(item_rows.find { |entry| entry.external_id == "of-77" }.payload).to eq(stored_payload)
    end

    it "backfills legacy provenance once and derives stable identities from it" do
      omnifocus_task.update_columns(
        source_service_name: nil, source_service_instance: nil, source_service_type: nil,
        source_external_id: nil, source_url: nil, first_observed_at: nil, last_observed_at: nil
      )
      asana_task.update_columns(
        source_service_name: nil, source_service_instance: nil, source_service_type: nil,
        source_external_id: nil, source_url: nil, first_observed_at: nil, last_observed_at: nil
      )

      run_backfill
      first_keys = OutboxEntry.order(:id).map(&:idempotency_key)

      travel_to(run_at + 1.hour) { described_class.run! }

      # The instance name inferred from parsed notes ("Asana:work") and the
      # default token for single-instance services both stay stable.
      expect(item_rows.find { |entry| entry.external_id == "asana-123" }.service_instance).to eq("asana:work")
      expect(item_rows.find { |entry| entry.external_id == "of-77" }.service_instance).to eq("omnifocus:default")
      expect(OutboxEntry.order(:id).map(&:idempotency_key)).to eq(first_keys)
    end
  end

  describe "skipped records" do
    it "counts records the pipeline cannot identify" do
      travel_to(observed_at) do
        Omnifocus::Task.create!(title: "No external id")
        Omnifocus::Task.create!(title: "Legacy untyped row", external_id: "of-99").update_column(:type, nil)
      end

      summary = run_backfill

      expect(summary[:items][:skipped_by_reason]).to eq("missing_external_id" => 1, "untyped_item" => 1)
      expect(item_rows.map(&:external_id)).not_to include("of-99")
    end
  end

  describe "dry run" do
    it "writes nothing and summarizes what a real run would enqueue" do
      omnifocus_task.update_columns(
        source_service_name: nil, source_service_instance: nil, source_service_type: nil,
        source_external_id: nil, source_url: nil, first_observed_at: nil, last_observed_at: nil
      )

      summary = run_backfill(dry_run: true)

      expect(OutboxEntry.count).to eq(0)
      expect(omnifocus_task.reload.last_observed_at).to be_nil
      expect(summary[:dry_run]).to be(true)
      expect(summary[:items][:enqueued_by_service])
        .to eq("omnifocus" => 1, "asana" => 1, "github" => 1, "google_tasks" => 1)
      expect(summary[:mappings]).to include(
        collections: 3,
        enqueued_by_confidence: { "confirmed" => 2, "inferred" => 2 }
      )

      write_summary = run_backfill
      expect(write_summary[:items]).to eq(summary[:items])
      expect(write_summary[:mappings]).to eq(summary[:mappings])
      expect(item_rows.count).to eq(4)
    end
  end
end
