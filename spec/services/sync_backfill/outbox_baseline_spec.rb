# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::OutboxBaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }

  def create_item(klass, external_id:, service_name:, sync_collection: nil, title: "Buy milk")
    travel_to(observed_at) do
      klass.create!(title:, external_id:, source_service_name: service_name, sync_collection:)
    end
  end

  describe ".run!" do
    it "enqueues a baseline item snapshot for each representative service" do
      create_item(Asana::Task, external_id: "asana-1", service_name: "Asana:work")
      create_item(Github::Issue, external_id: "gh-1", service_name: "Github:repo-1")
      create_item(GoogleTasks::Task, external_id: "gt-1", service_name: "GoogleTasks")
      omnifocus_item = create_item(Omnifocus::Task, external_id: "of-1", service_name: "Omnifocus")

      summary = described_class.run!

      rows = OutboxEntry.where(record_kind: "item").index_by(&:external_id)
      expect(rows.keys).to contain_exactly("asana-1", "gh-1", "gt-1", "of-1")
      expect(rows["asana-1"].service_instance).to eq("asana:work")
      expect(rows["gh-1"].service_instance).to eq("github:repo-1")
      expect(rows["gt-1"].service_instance).to eq("google_tasks:default")
      expect(rows["of-1"].service_instance).to eq("omnifocus:default")

      omnifocus_row = rows["of-1"]
      expect(omnifocus_row.payload).to include(
        "item_key" => omnifocus_item.item_key,
        "entity_type" => "task",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false
      )
      expect(omnifocus_row.payload["source"]).to eq(Outbox::SourceIdentity.for(omnifocus_item.reload).deep_stringify_keys)
      expect(omnifocus_row.payload["provenance"]).to include(
        "detected_by" => "backfill"
      )
      expect(omnifocus_row.payload["provenance"]["backfilled_at"]).to be_present

      expect(summary[:items][:by_service]).to eq(
        "asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1
      )
      expect(summary[:items][:skipped]).to eq(0)
    end

    it "counts items without an external id as skipped and does not enqueue them" do
      Asana::Task.create!(title: "No external id", source_service_name: "Asana")

      summary = described_class.run!

      expect(OutboxEntry.where(record_kind: "item")).to be_empty
      expect(summary[:items][:skipped]).to eq(1)
    end

    it "enqueues mapping rows only for confirmed/inferred confidence and withholds low" do
      high_collection = SyncCollection.create!(
        title: "High", mapping_method: "source_sync_id", mapping_confidence: "high",
        mapping_last_observed_at: observed_at
      )
      medium_collection = SyncCollection.create!(
        title: "Medium", mapping_method: "title_fallback", mapping_confidence: "medium",
        mapping_last_observed_at: observed_at
      )
      low_collection = SyncCollection.create!(
        title: "Low", mapping_method: "manual_backfill", mapping_confidence: "low",
        mapping_last_observed_at: observed_at
      )
      create_item(Asana::Task, external_id: "asana-high", service_name: "Asana", sync_collection: high_collection)
      create_item(Github::Issue, external_id: "gh-medium", service_name: "Github:repo-1", sync_collection: medium_collection)
      create_item(Omnifocus::Task, external_id: "of-low", service_name: "Omnifocus", sync_collection: low_collection)

      summary = described_class.run!

      mapping_rows = OutboxEntry.where(record_kind: "mapping")
      expect(mapping_rows.map(&:sync_collection_id)).to contain_exactly(high_collection.id, medium_collection.id)
      expect(mapping_rows.find_by(sync_collection_id: high_collection.id).payload["mapping_confidence"]).to eq("confirmed")
      expect(mapping_rows.find_by(sync_collection_id: medium_collection.id).payload["mapping_confidence"]).to eq("inferred")

      expect(summary[:mappings][:by_confidence]).to eq("high" => 1, "medium" => 1, "low" => 1)
      expect(summary[:mappings][:withheld_low_confidence]).to eq(1)
      expect(summary[:mappings][:skipped]).to eq(0)
    end

    it "counts sync_collections without mapping provenance as skipped" do
      SyncCollection.create!(title: "No provenance yet")

      summary = described_class.run!

      expect(OutboxEntry.where(record_kind: "mapping")).to be_empty
      expect(summary[:mappings][:skipped]).to eq(1)
    end

    it "does not write anything in dry_run mode but still reports accurate counts" do
      collection = SyncCollection.create!(
        title: "High", mapping_method: "source_sync_id", mapping_confidence: "high",
        mapping_last_observed_at: observed_at
      )
      create_item(Asana::Task, external_id: "asana-1", service_name: "Asana", sync_collection: collection)

      summary = described_class.run!(dry_run: true)

      expect(OutboxEntry.count).to eq(0)
      expect(summary[:items][:by_service]).to eq("asana" => 1)
      expect(summary[:mappings][:by_confidence]).to eq("high" => 1)
    end

    it "is idempotent across repeated runs" do
      collection = SyncCollection.create!(
        title: "High", mapping_method: "source_sync_id", mapping_confidence: "high",
        mapping_last_observed_at: observed_at
      )
      create_item(Asana::Task, external_id: "asana-1", service_name: "Asana", sync_collection: collection)

      first_summary = described_class.run!

      expect { described_class.run! }.not_to(change { OutboxEntry.count })
      expect(described_class.run!).to eq(first_summary)
    end
  end
end
