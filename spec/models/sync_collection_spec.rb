# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncCollection, :full_options do
  let(:test_item_class) do
    stub_const("SyncCollectionSpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "TestService"
      end

      def external_data
        @sync_item
      end
    end)
  end
  let(:other_item_class) do
    stub_const("OtherSyncCollectionSpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "OtherTestService"
      end

      def external_data
        @sync_item
      end
    end)
  end

  def build_item(attrs = {})
    sync_item = {
      "id" => attrs[:id] || SecureRandom.uuid,
      "title" => attrs[:title] || "Test Task",
      "completed" => attrs[:completed] || false,
      "notes" => attrs[:notes] || ""
    }
    test_item_class.new(
      sync_item: sync_item,
      options: options,
      title: attrs[:title] || "Test Task",
      external_id: attrs[:id] || sync_item["id"],
      completed: attrs[:completed] || false,
      notes: attrs[:notes] || "",
      last_modified: attrs[:last_modified]
    )
  end

  describe "#items" do
    it "returns an empty array when no items are associated" do
      collection = described_class.new(title: "Empty Collection")
      expect(collection.items).to eq([])
    end

    it "returns all linked sync_items through the STI table" do
      collection = described_class.create!(title: "Linked Collection")
      first_item = test_item_class.create!(title: "First", external_id: SecureRandom.uuid, sync_collection_id: collection.id)
      second_item = other_item_class.create!(title: "Second", external_id: SecureRandom.uuid, sync_collection_id: collection.id)

      expect(collection.items.map(&:external_id)).to contain_exactly(first_item.external_id, second_item.external_id)
    end
  end

  describe "#<<" do
    it "assigns the sync_collection_id to the item and saves" do
      item = build_item(title: "My Task")
      collection = described_class.new(title: "Test Collection")
      collection.define_singleton_method(:id) { 42 }
      allow(item).to receive(:save!)

      collection << item

      expect(item.sync_collection_id).to eq(42)
      expect(item).to have_received(:save!)
    end
  end

  describe "#needs_sync?" do
    it "returns true when last_synced is nil" do
      collection = described_class.new(title: "Never Synced")
      expect(collection.needs_sync?).to be true
    end

    it "returns false when last_synced is set and no items have been modified" do
      collection = described_class.create!(title: "Synced", last_synced: Time.current)
      expect(collection.needs_sync?).to be false
    end

    it "returns true when an item was modified after last_synced" do
      synced_at = 1.hour.ago
      collection = described_class.create!(title: "Synced", last_synced: synced_at)
      test_item_class.create!(title: "Modified Task", external_id: SecureRandom.uuid, sync_collection_id: collection.id, last_modified: Time.current)

      expect(collection.needs_sync?).to be true
    end

    it "returns false when all items were modified before last_synced" do
      synced_at = Time.current
      collection = described_class.create!(title: "Synced", last_synced: synced_at)
      test_item_class.create!(title: "Old Task", external_id: SecureRandom.uuid, sync_collection_id: collection.id, last_modified: 2.hours.ago)

      expect(collection.needs_sync?).to be false
    end

    it "handles items with nil last_modified gracefully" do
      synced_at = Time.current
      collection = described_class.create!(title: "Synced", last_synced: synced_at)
      test_item_class.create!(title: "No Dates", external_id: SecureRandom.uuid, sync_collection_id: collection.id)

      expect(collection.needs_sync?).to be false
    end
  end
end
