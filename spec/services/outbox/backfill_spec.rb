# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::Backfill do
  let(:now) { Time.zone.parse("2026-10-11T09:00:00Z") }
  let(:confirmed_at) { Time.zone.parse("2026-10-09T08:00:00Z") }
  let(:inferred_at) { Time.zone.parse("2026-10-09T09:30:00Z") }
  let(:low_at) { Time.zone.parse("2026-10-09T11:00:00Z") }

  let(:confirmed_collection) do
    SyncCollection.create!(title: "Buy milk", mapping_method: "source_sync_id", mapping_confidence: "high",
                           mapping_established_at: confirmed_at, mapping_last_observed_at: confirmed_at,
                           mapping_metadata: { "note_key" => "omnifocus_id" })
  end
  let(:inferred_collection) do
    SyncCollection.create!(title: "Release checklist", mapping_method: "title_fallback", mapping_confidence: "medium",
                           mapping_established_at: inferred_at, mapping_last_observed_at: inferred_at,
                           mapping_metadata: { "matched_by" => "title" })
  end
  let(:low_collection) do
    SyncCollection.create!(title: "Maybe linked", mapping_method: "manual_backfill", mapping_confidence: "low",
                           mapping_established_at: low_at, mapping_last_observed_at: low_at)
  end

  # Representative records for each real adapter family, created through
  # the actual STI classes the backfill reads back via Base::SyncItem.
  let(:omnifocus_item) do
    Omnifocus::Task.create!(title: "Buy milk", external_id: "of-77", notes: "asana_work_id: asana-123",
                            sync_collection: confirmed_collection, options: options_for("Omnifocus"))
  end
  let(:asana_item) do
    Asana::Task.create!(title: "Buy milk", external_id: "asana-123", notes: "omnifocus_id: of-77",
                        sync_collection: confirmed_collection, options: options_for("Asana:work"))
  end
  let(:github_item) do
    Github::Issue.create!(title: "Release checklist", external_id: "issue-42",
                          sync_collection: inferred_collection, options: options_for("Github:repo-1"))
  end
  let(:omnifocus_inferred_item) do
    Omnifocus::Task.create!(title: "Release checklist", external_id: "of-78",
                            sync_collection: inferred_collection, options: options_for("Omnifocus"))
  end
  let(:google_tasks_item) do
    GoogleTasks::Task.create!(title: "Maybe linked", external_id: "gt-9",
                              sync_collection: low_collection, options: options_for("GoogleTasks"))
  end
  let(:asana_low_item) do
    Asana::Task.create!(title: "Maybe linked", external_id: "asana-124",
                        sync_collection: low_collection, options: options_for("Asana:work"))
  end

  def options_for(service_name)
    { service_name:, services: [], primary: "Omnifocus", tags: [] }
  end

  def existing_items
    [omnifocus_item, asana_item, github_item, omnifocus_inferred_item, google_tasks_item, asana_low_item]
  end

  def stamp(time)
    time.utc.iso8601(6)
  end

  before { existing_items }

  describe "#run!" do
    it "enqueues one baseline item row per existing sync item across services" do
      summary = described_class.run!(now:)

      rows = OutboxEntry.where(record_kind: "item")
      expect(rows.map(&:external_id)).to contain_exactly("of-77", "asana-123", "issue-42", "of-78", "gt-9", "asana-124")
      expect(rows.map(&:event_type)).to all(be_nil)
      expect(summary[:items]).to include(publishable: 6, enqueued: 6, already_present: 0, skipped: 0)
      expect(summary[:items_by_service]).to eq("asana" => 2, "github" => 1, "google_tasks" => 1, "omnifocus" => 2)
    end

    it "identifies items through the provider identity, defaulting the instance token" do
      described_class.run!(now:)

      identities = OutboxEntry.where(record_kind: "item").index_by(&:external_id)
      expect(identities.values_at("of-77", "of-78")).to all(
        have_attributes(service_type: "omnifocus", service_instance: "omnifocus:default")
      )
      expect(identities["asana-123"]).to have_attributes(service_type: "asana", service_instance: "asana:work")
      expect(identities["issue-42"]).to have_attributes(service_type: "github", service_instance: "github:repo-1")
      expect(identities["gt-9"]).to have_attributes(service_type: "google_tasks", service_instance: "google_tasks:default")
    end

    it "publishes marked baseline snapshots with deterministic keys" do
      described_class.run!(now:)

      row = OutboxEntry.find_by(record_kind: "item", external_id: "of-77")
      expect(row.observed_at).to eq(omnifocus_item.reload.last_observed_at)
      expect(row.idempotency_key).to eq(
        "tb:v1:item:omnifocus:default:of-77:snapshot:#{stamp(omnifocus_item.last_observed_at)}"
      )
      expect(row.payload).to include(
        "contract_version" => 1,
        "item_key" => "omnifocus:of-77",
        "entity_type" => "task",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false,
        "sync_collection_id" => confirmed_collection.id
      )
      expect(row.payload["source"]).to include(
        "service_type" => "omnifocus",
        "service_instance" => "omnifocus:default",
        "external_id" => "of-77"
      )
      expect(row.payload["provenance"]).to eq("detected_by" => "backfill", "backfilled_at" => stamp(now))
    end

    it "stores each item's snapshot as the live diff baseline" do
      described_class.run!(now:)

      baseline = omnifocus_item.reload.last_snapshot
      expect(baseline).to include("title" => "Buy milk", "item_key" => "omnifocus:of-77", "is_deleted" => false)
      expect(baseline["observed_at"]).to eq(stamp(omnifocus_item.last_observed_at))
      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    end

    it "enqueues mapping rows for confirmed and inferred memberships only" do
      summary = described_class.run!(now:)

      rows = OutboxEntry.where(record_kind: "mapping")
      expect(rows.map(&:external_id)).to contain_exactly("of-77", "asana-123", "issue-42", "of-78")
      expect(rows.map { |row| row.payload["mapping_confidence"] }).to contain_exactly("confirmed", "confirmed",
                                                                                      "inferred", "inferred")
      expect(summary[:mappings]).to include(publishable: 4, enqueued: 4, withheld: 2, skipped: 0)
      expect(summary[:mappings_by_confidence]).to eq("confirmed" => 2, "inferred" => 2, "tentative" => 2)
    end

    it "publishes marked baseline mappings with deterministic keys" do
      described_class.run!(now:)

      row = OutboxEntry.find_by(record_kind: "mapping", external_id: "of-77")
      expect(row).to have_attributes(
        service_type: "omnifocus",
        service_instance: "omnifocus:default",
        sync_collection_id: confirmed_collection.id,
        observed_at: confirmed_at
      )
      expect(row.idempotency_key).to eq(
        "tb:v1:map:sync_collection:#{confirmed_collection.id}:membership:omnifocus:default:of-77:#{stamp(confirmed_at)}"
      )
      expect(row.payload["provenance"]).to include(
        "method" => "source_sync_id",
        "confidence" => "high",
        "detected_by" => "backfill",
        "backfilled_at" => stamp(now)
      )
    end

    it "never refreshes from or writes to providers, so external systems stay untouched" do
      [Omnifocus::Task, Asana::Task, Github::Issue, GoogleTasks::Task].each do |item_class|
        allow_any_instance_of(item_class).to receive(:read_original)
          .and_raise("backfill must not refresh from providers")
        allow_any_instance_of(item_class).to receive(:patch_external_attributes)
          .and_raise("backfill must not write to providers")
      end

      expect { described_class.run!(now:) }.not_to raise_error
      expect(OutboxEntry.where(record_kind: "item").count).to eq(6)
    end

    it "is idempotent: reruns leave rows and baselines untouched" do
      described_class.run!(now:)
      rows_before = OutboxEntry.all.to_a
      baseline_before = omnifocus_item.reload.last_snapshot

      summary = described_class.run!(now: now + 1.hour)

      expect(OutboxEntry.all.to_a).to match_array(rows_before)
      expect(summary[:items]).to include(enqueued: 0, already_present: 6)
      expect(summary[:mappings]).to include(enqueued: 0, already_present: 4, withheld: 2)
      expect(omnifocus_item.reload.last_snapshot).to eq(baseline_before)
    end
  end

  describe "incomplete records" do
    it "skips items and memberships without an external identity" do
      Github::Issue.create!(title: "No id yet", sync_collection: confirmed_collection, options: options_for("Github:repo-1"))

      summary = described_class.run!(now:)

      expect(summary[:items]).to include(publishable: 6, skipped: 1)
      expect(summary[:mappings]).to include(publishable: 4, skipped: 1, withheld: 2)
      expect(OutboxEntry.where(record_kind: "item").count).to eq(6)
      expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    end

    it "withholds memberships whose mapping provenance is still unknown" do
      low_collection.update_columns(mapping_method: nil, mapping_confidence: nil, mapping_last_observed_at: nil)

      summary = described_class.preview!(now:)

      expect(summary[:mappings]).to include(publishable: 4, withheld: 2, skipped: 0)
      expect(summary[:mappings_by_confidence]).to include("unknown" => 2)
      expect(summary[:provenance_pending]).to be(true)
    end
  end

  describe ".preview!" do
    it "reports what apply would publish without writing anything" do
      allow(SyncBackfill::SourceProvenance).to receive(:run!)

      summary = described_class.preview!(now:)

      expect(summary[:mode]).to eq("preview")
      expect(summary[:items]).to include(publishable: 6, enqueued: 0, already_present: 0, skipped: 0)
      expect(summary[:mappings]).to include(publishable: 4, withheld: 2, skipped: 0)
      expect(summary[:provenance_pending]).to be(false)
      expect(OutboxEntry.count).to eq(0)
      expect(github_item.reload.last_snapshot).to be_nil
      expect(SyncBackfill::SourceProvenance).not_to have_received(:run!)
    end
  end

  describe "provenance dependency" do
    it "backfills source and mapping provenance before publishing" do
      asana_item.update_columns(
        source_service_name: nil, source_service_instance: nil, source_service_type: nil,
        source_external_id: nil, source_url: nil, first_observed_at: nil, last_observed_at: nil
      )
      confirmed_collection.update_columns(
        mapping_method: nil, mapping_confidence: nil, mapping_metadata: nil,
        mapping_established_at: nil, mapping_last_observed_at: nil
      )

      summary = described_class.run!(now:)

      expect(asana_item.reload).to have_attributes(
        source_service_name: "Asana:work", source_external_id: "asana-123", first_observed_at: be_present
      )
      expect(confirmed_collection.reload).to have_attributes(mapping_method: "source_sync_id", mapping_confidence: "high")
      expect(summary[:provenance_pending]).to be(true)
      expect(OutboxEntry.where(record_kind: "item", external_id: "asana-123")).to be_present
    end
  end
end
