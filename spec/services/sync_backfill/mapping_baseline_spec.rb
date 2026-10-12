# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::MappingBaseline, :full_options do
  let(:now) { Time.zone.parse("2026-10-12T12:00:00.000000Z") }
  let(:logger) { instance_double(StructuredLogger, debug: nil) }

  before do
    Thread.current[:global_options] = options.merge(pretend: false)
  end

  def stub_item_class(const_name:, provider:)
    stub_const(const_name, Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      define_method(:provider) { provider }

      def external_data
        {}
      end
    end)
  end

  describe ".run!" do
    it "emits a mapping row per eligible member for high-confidence collections" do
      item_class = stub_item_class(const_name: "MappingBackfillItem", provider: "Github")
      collection = SyncCollection.create!(
        title: "Release checklist",
        mapping_method: "source_sync_id",
        mapping_confidence: "high",
        mapping_metadata: { "note_key" => "github_id" }
      )
      member = item_class.create!(
        title: "Release checklist",
        external_id: "gh-42",
        sync_collection: collection,
        options: options.merge(service_name: "Github:repo-1")
      )

      counts = described_class.run!(now:)

      expect(counts[:mappings_emitted]).to eq(1)
      row = OutboxEntry.find_by(record_kind: "mapping")
      expect(row.service_instance).to eq("github:repo-1")
      expect(row.sync_collection_id).to eq(collection.id)
      expect(row.payload).to include(
        "mapping_type" => "representation_membership",
        "membership_role" => "member",
        "mapping_confidence" => "confirmed",
        "mapping_source" => "sync_id_note"
      )
      expect(row.payload["sync_collection"]).to include(
        "sync_collection_id" => collection.id,
        "title" => "Release checklist"
      )
      expect(row.payload["member"]).to include(
        "item_key" => member.item_key,
        "service_instance" => "github:repo-1",
        "external_id" => "gh-42"
      )
    end

    it "translates medium-confidence mappings to 'inferred' confidence" do
      item_class = stub_item_class(const_name: "MappingBackfillMediumItem", provider: "Github")
      collection = SyncCollection.create!(
        title: "Release checklist",
        mapping_method: "title_fallback",
        mapping_confidence: "medium"
      )
      item_class.create!(
        title: "Release checklist",
        external_id: "gh-43",
        sync_collection: collection,
        options: options.merge(service_name: "Github:repo-1")
      )

      counts = described_class.run!(now:)

      expect(counts[:mappings_emitted]).to eq(1)
      expect(OutboxEntry.find_by(record_kind: "mapping").payload["mapping_confidence"]).to eq("inferred")
      expect(OutboxEntry.find_by(record_kind: "mapping").payload["mapping_source"]).to eq("title_match")
    end

    it "withholds low-confidence mappings and reports them in the counters" do
      item_class = stub_item_class(const_name: "MappingBackfillLowItem", provider: "Github")
      collection = SyncCollection.create!(
        title: "Release checklist",
        mapping_method: "manual_backfill",
        mapping_confidence: "low"
      )
      item_class.create!(
        title: "Release checklist",
        external_id: "gh-low",
        sync_collection: collection,
        options: options.merge(service_name: "Github:repo-1")
      )

      counts = described_class.run!(now:, logger:)

      expect(counts[:mappings_emitted]).to eq(0)
      expect(counts[:memberships_withheld_low_confidence]).to eq(1)
      expect(OutboxEntry.where(record_kind: "mapping")).to be_empty
      expect(logger).to have_received(:debug).with(/withholding low-confidence mapping/)
    end

    it "is idempotent across repeated runs" do
      item_class = stub_item_class(const_name: "MappingBackfillIdempotentItem", provider: "Github")
      collection = SyncCollection.create!(
        title: "Release checklist",
        mapping_method: "source_sync_id",
        mapping_confidence: "high"
      )
      item_class.create!(
        title: "Release checklist",
        external_id: "gh-44",
        sync_collection: collection,
        options: options.merge(service_name: "Github:repo-1")
      )

      described_class.run!(now:)
      first_id = OutboxEntry.find_by(record_kind: "mapping").id
      described_class.run!(now:)

      expect(OutboxEntry.where(record_kind: "mapping").count).to eq(1)
      expect(OutboxEntry.find_by(record_kind: "mapping").id).to eq(first_id)
    end

    it "withholds mappings whose confidence was never populated by the provenance backfill" do
      item_class = stub_item_class(const_name: "MappingBackfillUnsetItem", provider: "Github")
      collection = SyncCollection.create!(title: "Release checklist")
      item_class.create!(
        title: "Release checklist",
        external_id: "gh-no-conf",
        sync_collection: collection,
        options: options.merge(service_name: "Github:repo-1")
      )

      counts = described_class.run!(now:)

      expect(counts[:mappings_emitted]).to eq(0)
      expect(counts[:memberships_withheld_low_confidence]).to eq(1)
    end

    it "skips members without an external_id" do
      item_class = stub_item_class(const_name: "MappingBackfillSkipItem", provider: "Github")
      collection = SyncCollection.create!(
        title: "Release checklist",
        mapping_method: "source_sync_id",
        mapping_confidence: "high"
      )
      item_class.create!(
        title: "Release checklist",
        external_id: nil,
        sync_collection: collection,
        options: options.merge(service_name: "Github:repo-1")
      )

      counts = described_class.run!(now:)

      expect(counts[:memberships_skipped_incomplete]).to eq(1)
      expect(counts[:mappings_emitted]).to eq(0)
    end

    it "marks rows for unconfigured-instance services with the :default token" do
      item_class = stub_item_class(const_name: "MappingBackfillDefaultInstance", provider: "Omnifocus")
      collection = SyncCollection.create!(
        title: "Release checklist",
        mapping_method: "source_sync_id",
        mapping_confidence: "high"
      )
      item_class.create!(
        title: "Release checklist",
        external_id: "of-1",
        sync_collection: collection,
        options: options.merge(service_name: "Omnifocus")
      )

      counts = described_class.run!(now:)

      expect(counts[:mappings_emitted]).to eq(1)
      row = OutboxEntry.find_by(record_kind: "mapping")
      expect(row.service_instance).to eq("omnifocus:default")
      expect(row.payload["member"]["service_instance"]).to eq("omnifocus:default")
    end

    it "is a no-op in --pretend mode" do
      item_class = stub_item_class(const_name: "MappingBackfillPretendItem", provider: "Github")
      collection = SyncCollection.create!(
        title: "Release checklist",
        mapping_method: "source_sync_id",
        mapping_confidence: "high"
      )
      item_class.create!(
        title: "Release checklist",
        external_id: "gh-pretend",
        sync_collection: collection,
        options: options.merge(service_name: "Github:repo-1")
      )
      Thread.current[:global_options] = options.merge(pretend: true)

      counts = described_class.run!(now:)

      expect(counts[:mappings_emitted]).to eq(0)
      expect(OutboxEntry.count).to eq(0)
    end
  end
end
