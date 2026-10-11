# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::BaselineMappings do
  def member_for(klass, service_name:, external_id:)
    klass.create!(title: "Ship release", external_id:, options: { service_name:, services: [], primary: "Omnifocus", tags: [] })
  end

  let(:confirmed_collection) do
    SyncCollection.create!(title: "Confirmed mapping", mapping_method: "source_sync_id", mapping_confidence: "high")
  end
  let(:inferred_collection) do
    SyncCollection.create!(title: "Inferred mapping", mapping_method: "title_fallback", mapping_confidence: "medium")
  end
  let(:withheld_collection) do
    SyncCollection.create!(title: "Withheld mapping", mapping_method: "manual_backfill", mapping_confidence: "low")
  end
  let(:incomplete_collection) { SyncCollection.create!(title: "Not yet classified") }

  before do
    member_for(Asana::Task, service_name: "Asana:work", external_id: "asana-high").update!(sync_collection: confirmed_collection)
    member_for(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-high").update!(sync_collection: confirmed_collection)

    member_for(Github::Issue, service_name: "Github:repo-1", external_id: "issue-medium").update!(sync_collection: inferred_collection)
    member_for(GoogleTasks::Task, service_name: "GoogleTasks", external_id: "gtask-medium").update!(sync_collection: inferred_collection)

    member_for(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-low").update!(sync_collection: withheld_collection)
    member_for(Asana::Task, service_name: "Asana:work", external_id: "asana-low").update!(sync_collection: withheld_collection)

    member_for(Omnifocus::Task, service_name: "Omnifocus", external_id: "of-incomplete").update!(sync_collection: incomplete_collection)
  end

  describe "#summary" do
    it "counts eligible memberships by confidence and lists withheld and incomplete collections without writing anything" do
      summary = described_class.new.summary

      expect(summary[:by_confidence]).to eq("high" => 2, "medium" => 2)
      expect(summary[:withheld]).to contain_exactly({ id: withheld_collection.id, confidence: "low" })
      expect(summary[:incomplete]).to contain_exactly(incomplete_collection.id)
      expect(OutboxEntry.count).to eq(0)
    end
  end

  describe "#run!" do
    it "publishes confirmed and inferred mapping rows but withholds low-confidence ones" do
      described_class.new.run!

      rows = OutboxEntry.where(record_kind: "mapping")
      expect(rows.pluck(:external_id)).to contain_exactly("asana-high", "of-high", "issue-medium", "gtask-medium")
      expect(rows.map { |row| row.payload["mapping_confidence"] }).to contain_exactly("confirmed", "confirmed", "inferred", "inferred")
      expect(OutboxEntry.where(sync_collection_id: withheld_collection.id)).to be_empty
      expect(OutboxEntry.where(sync_collection_id: incomplete_collection.id)).to be_empty
    end

    it "is idempotent across repeated runs" do
      described_class.new.run!

      expect { described_class.new.run! }.not_to(change { OutboxEntry.where(record_kind: "mapping").count })
    end
  end
end
