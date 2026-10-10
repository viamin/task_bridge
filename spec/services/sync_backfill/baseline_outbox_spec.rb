# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::BaselineOutbox do
  let(:backfilled_at) { Time.zone.parse("2026-10-10T12:00:00Z") }
  let(:options) { { services: [], primary: "Omnifocus", tags: [] } }
  let(:backfill) { described_class.new(backfilled_at:) }

  def create_item(item_class, attributes)
    item_class.create!({ options: }.merge(attributes))
  end

  # Legacy rows predate the provenance columns (#216): wipe them so the
  # backfill has to rebuild identity from STI type, notes, and timestamps.
  def deprove(item)
    item.update_columns(
      source_service_name: nil,
      source_service_instance: nil,
      source_service_type: nil,
      source_external_id: nil,
      source_url: nil,
      source_created_at: nil,
      source_updated_at: nil,
      first_observed_at: nil,
      last_observed_at: nil,
      source_metadata: nil
    )
  end

  def deprove_collection(collection)
    collection.update_columns(
      mapping_method: nil,
      mapping_confidence: nil,
      mapping_metadata: nil,
      mapping_established_at: nil,
      mapping_last_observed_at: nil
    )
  end

  def baseline_rows
    OutboxEntry.where(record_kind: "item")
  end

  def mapping_rows
    OutboxEntry.where(record_kind: "mapping")
  end

  before { Thread.current[:global_options] = nil }

  describe "#perform" do
    it "enqueues one baseline item snapshot per existing item across services" do
      collection = SyncCollection.create!(title: "Buy milk")
      asana_item = create_item(Asana::Task,
                               title: "Buy milk",
                               external_id: "asana-1",
                               url: "https://app.asana.com/0/1/asana-1",
                               notes: "omnifocus_id: of-1",
                               sync_collection: collection,
                               options: options.merge(service_name: "Asana:work"))
      omnifocus_item = create_item(Omnifocus::Task,
                                   title: "Buy milk",
                                   external_id: "of-1",
                                   url: "omnifocus:///task/of-1",
                                   notes: "asana_work_id: asana-1",
                                   sync_collection: collection)
      github_item = create_item(Github::Issue,
                                title: "Release checklist",
                                external_id: "issue-42",
                                status: "open")
      google_tasks_item = create_item(GoogleTasks::Task,
                                      title: "Buy milk",
                                      external_id: "gt-1")
      [asana_item, omnifocus_item, github_item, google_tasks_item].each { |item| deprove(item) }

      backfill.perform
      summary = backfill.summary

      expect(baseline_rows.count).to eq(4)
      expect(baseline_rows.map(&:service_type)).to contain_exactly("omnifocus", "asana", "github", "google_tasks")
      expect(baseline_rows.map(&:service_instance)).to contain_exactly(
        "omnifocus:default", "asana:work", "github:default", "google_tasks:default"
      )
      expect(OutboxEntry.where(record_kind: %w[observation sync_run])).to be_empty

      omnifocus_row = baseline_rows.find_by(external_id: "of-1")
      expect(omnifocus_row.observed_at).to eq(omnifocus_item.reload.last_observed_at)
      expect(omnifocus_row.idempotency_key).to eq(
        "tb:v1:item:omnifocus:default:of-1:snapshot:#{omnifocus_row.observed_at.utc.iso8601(6)}"
      )
      expect(omnifocus_row.payload).to include(
        "item_key" => "omnifocus:of-1",
        "entity_type" => "task",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false
      )
      expect(omnifocus_row.payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-1",
        "source_url" => "omnifocus:///task/of-1"
      )
      expect(baseline_rows.find_by(external_id: "asana-1").payload["source"]).to include(
        "service_type" => "asana",
        "service_instance" => "asana:work",
        "external_id" => "asana-1"
      )
      expect(baseline_rows.find_by(external_id: "gt-1").payload["source"]["service_instance"])
        .to eq("google_tasks:default")
      expect(summary[:items]).to include(enqueued: 4, existing: 0, skipped: 0, errors: 0)
      expect(summary[:items][:by_service]).to eq(
        "omnifocus" => 1, "asana" => 1, "github" => 1, "google_tasks" => 1
      )
    end

    it "marks rows as backfilled baseline state, not historical change events" do
      item = create_item(GoogleTasks::Task, title: "Water plants", external_id: "gt-9")
      deprove(item)

      backfill.perform

      payload = baseline_rows.find_by(external_id: "gt-9").payload
      expect(payload["provenance"]).to eq(
        "detected_by" => "backfill",
        "baseline" => true,
        "backfilled_at" => backfilled_at.utc.iso8601(6)
      )
      expect(payload).not_to include("event_type", "change", "snapshot")
      expect(baseline_rows.find_by(external_id: "gt-9").event_type).to be_nil
    end

    it "matches the live pipeline's published snapshot shape" do
      item = create_item(Omnifocus::Task, title: "Buy milk", external_id: "of-2")

      backfill.perform

      # Compare against a freshly loaded instance so both sides see the
      # same run-scoped options a rake task would use.
      expect(baseline_rows.find_by(external_id: "of-2").payload.except("provenance"))
        .to eq(Base::SnapshotSerializer.published(Omnifocus::Task.find(item.id)).deep_stringify_keys)
    end

    it "is idempotent: reruns reuse the same rows and keys" do
      item = create_item(Asana::Task, title: "Buy milk", external_id: "asana-7")
      deprove(item)
      backfill.perform
      first_rows = baseline_rows.to_a
      first_summary = backfill.summary

      rerun = described_class.new(backfilled_at: backfilled_at + 1.hour)
      rerun.perform
      rerun_summary = rerun.summary

      expect(baseline_rows.count).to eq(1)
      expect(baseline_rows.to_a).to eq(first_rows)
      expect(first_summary[:items]).to include(enqueued: 1, existing: 0)
      expect(rerun_summary[:items]).to include(enqueued: 0, existing: 1, errors: 0)
    end

    it "skips items without an external id and counts them" do
      create_item(Omnifocus::Task, title: "No identity", external_id: nil)

      backfill.perform
      summary = backfill.summary

      expect(baseline_rows).to be_empty
      expect(summary[:items]).to include(skipped: 1, enqueued: 0, errors: 0)
    end

    it "counts rows it cannot serialize instead of aborting the run" do
      create_item(Github::Issue, title: nil, external_id: "issue-unserializable")
      create_item(Omnifocus::Task, title: "Fine", external_id: "of-3")

      expect { backfill.perform }.to output(/skipping Github::Issue/).to_stderr

      expect(baseline_rows.map(&:external_id)).to eq(["of-3"])
      expect(backfill.summary[:items]).to include(enqueued: 1, errors: 1)
    end

    it "backfills provenance for legacy rows before snapshotting them" do
      collection = SyncCollection.create!(title: "Buy milk")
      asana_item = create_item(Asana::Task,
                               title: "Buy milk",
                               external_id: "asana-2",
                               sync_collection: collection,
                               options: options.merge(service_name: "Asana:work"))
      omnifocus_peer = create_item(Omnifocus::Task,
                                   title: "Buy milk",
                                   external_id: "of-2",
                                   notes: "asana_work_id: asana-2",
                                   sync_collection: collection)
      [asana_item, omnifocus_peer].each { |item| deprove(item) }

      backfill.perform

      reloaded = asana_item.reload
      expect(reloaded.source_service_name).to eq("Asana:work")
      expect(reloaded.source_service_instance).to eq("work")
      expect(reloaded.source_external_id).to eq("asana-2")
      expect(reloaded.first_observed_at).to be_present
      expect(reloaded.last_observed_at).to be_present
      row = baseline_rows.find_by(external_id: "asana-2")
      expect(row.observed_at).to eq(reloaded.last_observed_at)
      expect(row.payload["source"]["service_instance"]).to eq("asana:work")
    end

    it "never enters external fetch or mutation paths" do
      create_item(Github::Issue, title: "Release checklist", external_id: "issue-7", notes: "context")
      allow_any_instance_of(Base::SyncItem).to receive(:service)
        .and_raise(RuntimeError, "the backfill must not touch service clients")
      allow_any_instance_of(Base::SyncItem).to receive(:read_original)
        .and_raise(RuntimeError, "the backfill must not fetch from sources")
      allow_any_instance_of(Base::SyncItem).to receive(:refresh_from_external!)
        .and_raise(RuntimeError, "the backfill must not refresh from sources")

      expect { backfill.perform }.not_to raise_error

      expect(baseline_rows.map(&:external_id)).to eq(["issue-7"])
    end
  end

  describe "mapping memberships" do
    it "publishes sync-id derived memberships as confirmed" do
      collection = SyncCollection.create!(title: "Buy milk")
      asana_item = create_item(Asana::Task,
                               title: "Buy milk",
                               external_id: "asana-10",
                               notes: "omnifocus_id: of-10",
                               sync_collection: collection,
                               options: options.merge(service_name: "Asana:work"))
      omnifocus_item = create_item(Omnifocus::Task,
                                   title: "Buy milk",
                                   external_id: "of-10",
                                   notes: "asana_work_id: asana-10",
                                   sync_collection: collection)
      [asana_item, omnifocus_item].each { |item| deprove(item) }
      deprove_collection(collection)

      backfill.perform
      summary = backfill.summary

      collection.reload
      expect(collection.mapping_method).to eq("source_sync_id")
      expect(collection.mapping_confidence).to eq("high")
      expect(mapping_rows.map(&:external_id)).to contain_exactly("asana-10", "of-10")
      asana_row = mapping_rows.find_by(external_id: "asana-10")
      expect(asana_row.payload).to include(
        "mapping_confidence" => "confirmed",
        "mapping_source" => "sync_id_note"
      )
      expect(asana_row.observed_at).to eq(collection.mapping_last_observed_at)
      expect(asana_row.idempotency_key).to eq(
        "tb:v1:map:sync_collection:#{collection.id}:membership:asana:work:asana-10:" \
        "#{collection.mapping_last_observed_at.utc.iso8601(6)}"
      )
      expect(summary[:mappings]).to include(enqueued: 2, withheld: 0, errors: 0)
      expect(summary[:mappings][:by_confidence]).to eq("confirmed" => 2)
    end

    it "publishes title-derived memberships as inferred, separate from confirmed" do
      collection = SyncCollection.create!(
        title: "Release checklist",
        mapping_method: "title_fallback",
        mapping_confidence: "medium",
        mapping_last_observed_at: Time.zone.parse("2026-10-09T09:00:00Z")
      )
      create_item(Github::Issue, title: "Release checklist", external_id: "issue-20",
                                 sync_collection: collection)
      create_item(Omnifocus::Task, title: "Release checklist", external_id: "of-20",
                                   sync_collection: collection)

      backfill.perform
      summary = backfill.summary

      expect(mapping_rows.count).to eq(2)
      expect(mapping_rows.map { |row| row.payload["mapping_confidence"] }).to all(eq("inferred"))
      expect(mapping_rows.map { |row| row.payload["mapping_source"] }).to all(eq("title_match"))
      expect(summary[:mappings][:by_confidence]).to eq("inferred" => 2)
    end

    it "withholds low-confidence memberships from publication but keeps them countable" do
      collection = SyncCollection.create!(
        title: "Unclear pair",
        mapping_method: "manual_backfill",
        mapping_confidence: "low",
        mapping_last_observed_at: Time.zone.parse("2026-10-09T09:00:00Z")
      )
      create_item(Omnifocus::Task, title: "One thing", external_id: "of-30",
                                   sync_collection: collection)
      create_item(Reclaim::Task, title: "Another thing", external_id: "rc-30",
                                 sync_collection: collection)

      backfill.perform
      summary = backfill.summary

      expect(mapping_rows).to be_empty
      expect(baseline_rows.count).to eq(2)
      expect(summary[:mappings]).to include(withheld: 2, enqueued: 0)
      expect(summary[:mappings][:withheld_by_confidence]).to eq("low" => 2)
    end

    it "counts members without an external id as skipped" do
      collection = SyncCollection.create!(
        title: "Partial",
        mapping_method: "source_sync_id",
        mapping_confidence: "high",
        mapping_last_observed_at: Time.zone.parse("2026-10-09T09:00:00Z")
      )
      create_item(Omnifocus::Task, title: "Complete", external_id: "of-40",
                                   sync_collection: collection)
      create_item(GoogleTasks::Task, title: "Incomplete", external_id: nil,
                                     sync_collection: collection)

      backfill.perform
      summary = backfill.summary

      expect(mapping_rows.map(&:external_id)).to eq(["of-40"])
      expect(summary[:mappings]).to include(skipped_members: 1)
    end

    it "reruns without duplicating mapping rows" do
      collection = SyncCollection.create!(
        title: "Stable",
        mapping_method: "source_sync_id",
        mapping_confidence: "high",
        mapping_last_observed_at: Time.zone.parse("2026-10-09T09:00:00Z")
      )
      create_item(Omnifocus::Task, title: "Stable", external_id: "of-50",
                                   sync_collection: collection)
      backfill.perform
      first_rows = mapping_rows.to_a

      rerun = described_class.new(backfilled_at: backfilled_at + 1.hour)
      rerun.perform
      rerun_summary = rerun.summary

      expect(mapping_rows.to_a).to eq(first_rows)
      expect(rerun_summary[:mappings]).to include(enqueued: 0, existing: 1)
    end
  end

  describe ".dry_run!" do
    it "reports the same counts a real run would produce without writing anything" do
      collection = SyncCollection.create!(
        title: "Withheld",
        mapping_method: "manual_backfill",
        mapping_confidence: "low",
        mapping_last_observed_at: Time.zone.parse("2026-10-09T09:00:00Z")
      )
      item = create_item(Omnifocus::Task, title: "Buy milk", external_id: "of-60",
                                          sync_collection: collection)
      deprove(item)
      create_item(GoogleTasks::Task, title: "Buy milk", external_id: "gt-60",
                                     sync_collection: collection)

      summary = described_class.dry_run!(backfilled_at:)

      expect(summary[:dry_run]).to be(true)
      expect(summary[:items]).to include(enqueued: 2, skipped: 0, errors: 0)
      expect(summary[:mappings]).to include(withheld: 2)
      expect(summary[:mappings][:withheld_by_confidence]).to eq("low" => 2)

      expect(OutboxEntry.count).to eq(0)
      reloaded = item.reload
      expect(reloaded.source_service_name).to be_nil
      expect(reloaded.last_observed_at).to be_nil
      expect(collection.reload.mapping_confidence).to eq("low")
    end
  end

  describe ".run!" do
    it "performs and returns the summary" do
      create_item(Github::Issue, title: "Release checklist", external_id: "issue-80")

      summary = described_class.run!(backfilled_at:)

      expect(summary[:dry_run]).to be(false)
      expect(summary[:items]).to include(enqueued: 1)
      expect(baseline_rows.count).to eq(1)
    end
  end
end
