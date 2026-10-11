# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::BaselineBackfill do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:options) do
    { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] }
  end

  # Representative records across the four required services, mirroring
  # real synchronized data: OmniFocus/Asana linked by sync-id notes, a
  # GitHub issue, and a Google Tasks task.
  let!(:confirmed_collection) do
    SyncCollection.create!(title: "Buy milk", mapping_method: "source_sync_id", mapping_confidence: "high")
  end
  let!(:inferred_collection) do
    SyncCollection.create!(title: "Fix login", mapping_method: "title_fallback", mapping_confidence: "medium")
  end
  let!(:withheld_collection) do
    SyncCollection.create!(title: "Unlinked pair", mapping_method: "manual_backfill", mapping_confidence: "low")
  end
  let!(:omnifocus_task) do
    Omnifocus::Task.create!(
      title: "Buy milk", external_id: "of-1", notes: "asana_work_id: asana-1",
      options: options.merge(service_name: "Omnifocus"), sync_collection: confirmed_collection
    )
  end
  let!(:asana_task) do
    Asana::Task.create!(
      title: "Buy milk", external_id: "asana-1", notes: "omnifocus_id: of-1",
      options: options.merge(service_name: "Asana:work"), sync_collection: confirmed_collection
    )
  end
  let!(:github_issue) do
    Github::Issue.create!(
      title: "Fix login", external_id: "gh-42",
      options: options.merge(service_name: "Github:repo-1"), sync_collection: inferred_collection
    )
  end
  let!(:google_task) do
    GoogleTasks::Task.create!(
      title: "Buy milk", external_id: "gt-9",
      options: options.merge(service_name: "GoogleTasks"), sync_collection: inferred_collection
    )
  end
  let!(:withheld_items) do
    [
      Instapaper::Article.create!(title: "Unlinked", external_id: "ip-7",
                                  options: options.merge(service_name: "Instapaper"),
                                  sync_collection: withheld_collection),
      Omnifocus::Task.create!(title: "Unlinked", external_id: "of-99",
                              options: options.merge(service_name: "Omnifocus"),
                              sync_collection: withheld_collection)
    ]
  end
  let!(:incomplete_item) do
    Reminders::Reminder.create!(
      title: "No external id yet", external_id: nil,
      options: options.merge(service_name: "Reminders")
    )
  end

  def item_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  def run_backfill(dry_run: false)
    travel_to(now) { described_class.run!(dry_run:) }
  end

  def strip_provenance(item)
    item.update_columns(
      source_service_name: nil, source_service_instance: nil, source_service_type: nil,
      source_external_id: nil, source_url: nil, source_updated_at: nil,
      first_observed_at: nil, last_observed_at: nil, source_metadata: nil
    )
  end

  describe "baseline item snapshots" do
    it "enqueues one item row per existing item with a stable default service instance" do
      run_backfill

      expect(item_rows.count).to eq(6)
      expect(item_rows.map(&:external_id)).to contain_exactly("of-1", "asana-1", "gh-42", "gt-9", "ip-7", "of-99")
      expect(item_rows.find_by(external_id: "of-1")).to have_attributes(
        service_type: "omnifocus",
        service_instance: "omnifocus:default",
        event_type: nil
      )
      expect(item_rows.find_by(external_id: "asana-1").service_instance).to eq("asana:work")
      expect(item_rows.find_by(external_id: "gh-42").service_instance).to eq("github:repo-1")
      expect(item_rows.find_by(external_id: "gt-9").service_instance).to eq("google_tasks:default")
    end

    it "marks snapshots as baseline observations rather than change events" do
      run_backfill

      payload = item_rows.find_by(external_id: "of-1").payload
      expect(payload["provenance"]).to include(
        "detected_by" => "backfill",
        "backfilled_at" => "2026-10-11T12:00:00.000000Z"
      )
      expect(payload).to include(
        "contract_version" => 1,
        "item_key" => "omnifocus:of-1",
        "entity_type" => "task",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false,
        "source" => including(
          "service_type" => "omnifocus",
          "service_instance" => "omnifocus:default",
          "external_id" => "of-1"
        )
      )
      # Baseline rows are item snapshots, never fabricated history.
      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
      expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    end

    it "keys rows on the stored observation timestamp so reruns are safe" do
      run_backfill

      row = item_rows.find_by(external_id: "gt-9")
      expect(row.observed_at).to eq(google_task.reload.last_observed_at)
      expect(row.idempotency_key).to eq(
        Outbox::IdempotencyKey.for(
          record_kind: :item, observed_at: row.observed_at,
          service_instance: "google_tasks:default", external_id: "gt-9"
        )
      )
    end
  end

  describe "mapping rows" do
    it "publishes confirmed and inferred memberships and withholds low confidence" do
      summary = run_backfill

      expect(mapping_rows.count).to eq(4)
      confirmed = mapping_rows.where(sync_collection_id: confirmed_collection.id)
      expect(confirmed.map { |row| row.payload["mapping_confidence"] }).to all(eq("confirmed"))
      expect(confirmed.map { |row| row.payload["mapping_source"] }).to all(eq("sync_id_note"))
      inferred = mapping_rows.where(sync_collection_id: inferred_collection.id)
      expect(inferred.map { |row| row.payload["mapping_confidence"] }).to all(eq("inferred"))
      expect(inferred.map { |row| row.payload["mapping_source"] }).to all(eq("title_match"))
      # Low-confidence memberships never reach the outbox...
      expect(mapping_rows.where(sync_collection_id: withheld_collection.id)).to be_empty
      # ...but stay identifiable through the summary counts.
      expect(summary[:mappings]).to include(
        memberships: 6, enqueued: 4, withheld: 2,
        by_confidence: including("high" => 2, "medium" => 2, "low" => 2)
      )
    end

    it "marks mapping provenance as backfill" do
      run_backfill

      payload = mapping_rows.find_by(external_id: "asana-1").payload
      expect(payload).to include(
        "mapping_type" => "representation_membership",
        "membership_role" => "member",
        "mapping_confidence" => "confirmed",
        "mapping_source" => "sync_id_note"
      )
      expect(payload["member"]).to include("item_key" => "asana_work:asana-1", "external_id" => "asana-1")
      expect(payload["sync_collection"]).to include(
        "sync_collection_id" => confirmed_collection.id,
        "title" => "Buy milk"
      )
      expect(payload["provenance"]).to include(
        "method" => "source_sync_id",
        "confidence" => "high",
        "detected_by" => "backfill",
        "backfilled_at" => "2026-10-11T12:00:00.000000Z"
      )
      expect(payload["observed_at"]).to eq(
        confirmed_collection.reload.mapping_last_observed_at&.utc&.iso8601(6) ||
          confirmed_collection.updated_at.utc.iso8601(6)
      )
    end

    it "skips memberships whose member has no external id" do
      incomplete_item.update!(sync_collection_id: confirmed_collection.id)

      summary = run_backfill

      expect(mapping_rows.where(external_id: nil)).to be_empty
      expect(summary[:mappings]).to include(enqueued: 4, memberships: 7, skipped: 1, withheld: 2)
    end
  end

  describe "idempotency" do
    it "reuses stored rows on rerun instead of duplicating facts" do
      first_summary = run_backfill

      expect(first_summary[:items]).to include(total: 7, enqueued: 6, existing: 0, skipped: 1)
      expect(first_summary[:items][:by_service]).to include(
        "Omnifocus" => including(total: 2, enqueued: 2),
        "Asana:work" => including(total: 1, enqueued: 1),
        "Github:repo-1" => including(total: 1, enqueued: 1),
        "GoogleTasks" => including(total: 1, enqueued: 1)
      )
      expect(first_summary[:items][:skipped_reasons]).to include("missing_external_id" => 1)

      second_summary = run_backfill

      expect(second_summary[:items]).to include(enqueued: 0, existing: 6, skipped: 1)
      expect(second_summary[:mappings]).to include(enqueued: 0, existing: 4)
      expect(item_rows.count).to eq(6)
      expect(mapping_rows.count).to eq(4)
    end

    it "fills legacy provenance through the provenance backfill before keying rows" do
      strip_provenance(asana_task)
      strip_provenance(omnifocus_task)

      run_backfill

      # Inferred from the peer's sync-id note key: Asana:work, not Asana.
      expect(asana_task.reload).to have_attributes(
        source_service_name: "Asana:work",
        source_external_id: "asana-1",
        first_observed_at: asana_task.last_observed_at
      )
      expect(omnifocus_task.reload.source_service_name).to eq("Omnifocus")
      row = item_rows.find_by(external_id: "asana-1")
      expect(row).to have_attributes(service_instance: "asana:work", observed_at: asana_task.last_observed_at)
      expect(row.payload["source"]["service_instance"]).to eq("asana:work")
    end
  end

  describe "dry run" do
    it "summarizes without writing anything" do
      strip_provenance(omnifocus_task)
      summary = nil

      expect { summary = run_backfill(dry_run: true) }.not_to(change { OutboxEntry.count })
      expect(OutboxEntry.count).to eq(0)
      expect(summary[:dry_run]).to be(true)
      expect(summary[:items]).to include(total: 7, enqueued: 6, existing: 0, skipped: 1)
      expect(summary[:mappings]).to include(enqueued: 4, withheld: 2, memberships: 6)
      expect(summary[:mappings][:by_confidence]).to include("low" => 2)
      # Provenance backfill is skipped entirely in dry-run mode.
      expect(omnifocus_task.reload.last_observed_at).to be_nil
    end
  end

  describe "safety" do
    it "does not mutate externally-owned item data or contact external systems" do
      expect_any_instance_of(Base::SyncItem).not_to receive(:patch_external_attributes)

      run_backfill

      expect(omnifocus_task.reload).to have_attributes(
        title: "Buy milk", external_id: "of-1", notes: "asana_work_id: asana-1"
      )
      expect(asana_task.reload).to have_attributes(title: "Buy milk", external_id: "asana-1")
      expect(github_issue.reload).to have_attributes(title: "Fix login", external_id: "gh-42")
      expect(google_task.reload).to have_attributes(title: "Buy milk", external_id: "gt-9")
      expect(withheld_collection.reload).to have_attributes(
        mapping_method: "manual_backfill", mapping_confidence: "low"
      )
    end
  end
end
