# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::MappingObservations do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }

  def create_item(klass, service_name:, external_id:, sync_collection:, title: "Buy milk")
    klass.create!(
      options: { service_name:, services: [], primary: "Omnifocus", tags: [] },
      title:,
      external_id:,
      sync_collection:
    )
  end

  def create_collection(method:, confidence:)
    SyncCollection.create!(title: "Backfilled mapping", mapping_method: method, mapping_confidence: confidence,
                           mapping_last_observed_at: observed_at)
  end

  describe ".run!" do
    it "enqueues confirmed and inferred memberships but withholds low-confidence ones from publication" do
      high_collection = create_collection(method: "source_sync_id", confidence: "high")
      medium_collection = create_collection(method: "title_fallback", confidence: "medium")
      low_collection = create_collection(method: "manual_backfill", confidence: "low")

      create_item(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-1", sync_collection: high_collection)
      create_item(Asana::Task, service_name: "Asana:work", external_id: "asana-1", sync_collection: high_collection)
      create_item(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-2", sync_collection: medium_collection)
      create_item(Github::Issue, service_name: "Github:repo-1", external_id: "issue-2", sync_collection: medium_collection)
      create_item(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-3", sync_collection: low_collection)
      create_item(GoogleTasks::Task, service_name: "GoogleTasks", external_id: "gt-3", sync_collection: low_collection)

      summary = described_class.run!

      expect(summary).to eq(
        enqueued: 4,
        withheld_low_confidence: 2,
        skipped_incomplete: 0,
        by_confidence: { "high" => 2, "medium" => 2, "low" => 2 },
        by_service: { "omnifocus" => 2, "asana" => 1, "github" => 1 }
      )

      expect(OutboxEntry.where(record_kind: "mapping", sync_collection_id: high_collection.id).count).to eq(2)
      expect(OutboxEntry.where(record_kind: "mapping", sync_collection_id: medium_collection.id).count).to eq(2)
      expect(OutboxEntry.where(record_kind: "mapping", sync_collection_id: low_collection.id)).to be_empty

      expect(OutboxEntry.find_by(record_kind: "mapping", external_id: "asana-1").payload["mapping_confidence"]).to eq("confirmed")
      expect(OutboxEntry.find_by(record_kind: "mapping", external_id: "issue-2").payload["mapping_confidence"]).to eq("inferred")
    end

    it "skips collections that have not been through mapping provenance backfill" do
      collection = SyncCollection.create!(title: "No provenance yet")
      create_item(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-4", sync_collection: collection)

      summary = described_class.run!

      expect(summary).to eq(
        enqueued: 0,
        withheld_low_confidence: 0,
        skipped_incomplete: 1,
        by_confidence: {},
        by_service: {}
      )
      expect(OutboxEntry.where(record_kind: "mapping")).to be_empty
    end

    it "is idempotent across repeated runs" do
      collection = create_collection(method: "source_sync_id", confidence: "high")
      create_item(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-5", sync_collection: collection)
      create_item(Asana::Task, service_name: "Asana:work", external_id: "asana-5", sync_collection: collection)

      described_class.run!

      expect { described_class.run! }.not_to(change { OutboxEntry.where(record_kind: "mapping").count })
    end

    it "reports counts without writing outbox rows in dry-run mode" do
      collection = create_collection(method: "source_sync_id", confidence: "high")
      create_item(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-6", sync_collection: collection)
      create_item(Asana::Task, service_name: "Asana:work", external_id: "asana-6", sync_collection: collection)

      summary = described_class.run!(dry_run: true)

      expect(summary[:enqueued]).to eq(2)
      expect(OutboxEntry.where(record_kind: "mapping")).to be_empty
    end
  end
end
