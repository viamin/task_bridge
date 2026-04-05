# frozen_string_literal: true

require "rails_helper"

RSpec.describe "task_bridge:sync collection grouping", :full_options do
  # Tests for the item-grouping logic in sync.rake lines 67-78.
  # We extract the grouping algorithm and test it with stubbed items
  # rather than loading the full rake environment.

  let(:test_item_class) do
    Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        @provider || "TestService"
      end

      def external_data
        @sync_item
      end
    end
  end

  def build_item(attrs = {})
    sync_item = {
      "id" => attrs[:id] || SecureRandom.uuid,
      "title" => attrs[:title] || "Test Task",
      "completed" => attrs[:completed] || false,
      "notes" => attrs[:notes] || ""
    }
    item = test_item_class.new(
      sync_item: sync_item,
      options: options,
      title: attrs[:title] || "Test Task",
      external_id: attrs[:id] || sync_item["id"],
      completed: attrs[:completed] || false,
      notes: attrs[:notes] || "",
      last_modified: attrs[:last_modified],
      sync_collection_id: attrs[:sync_collection_id]
    )
    item.instance_variable_set(:@provider, attrs[:provider]) if attrs[:provider]
    item
  end

  # Replicate the grouping logic from sync.rake
  def group_items_into_collections(items_by_service)
    items_by_service.each do |service_name, items|
      items.each do |item|
        next if item.provider.present? && item.provider != "TestService"

        item.instance_variable_set(:@provider, service_name.to_s)
      end
    end

    items_by_collection = items_by_service.values.flatten.group_by(&:sync_collection_id)
    ungrouped_items = items_by_collection.delete(nil) || []
    ungrouped_items_by_title = ungrouped_items.group_by(&:title)
    collections = []

    ungrouped_items_by_title.each do |title, items|
      providers = items.map(&:provider)
      next unless items.count > 1 &&
                  items.any?(&:incomplete?) &&
                  providers.uniq.count == items.count &&
                  items.count <= items_by_service.keys.length

      collection = SyncCollection.create(title: title)
      items.each { |item| collection << item }
      items_by_collection[collection.id] = items
      collections << collection
    end

    { items_by_collection: items_by_collection, collections: collections }
  end

  describe "grouping items by sync_collection_id" do
    it "groups items that already have a sync_collection_id" do
      collection = SyncCollection.create(title: "Existing")
      item1 = build_item(title: "Task A", id: "a1", sync_collection_id: collection.id)
      item2 = build_item(title: "Task A", id: "a2", sync_collection_id: collection.id)

      result = group_items_into_collections(ServiceA: [item1], ServiceB: [item2])

      expect(result[:items_by_collection][collection.id]).to contain_exactly(item1, item2)
    end

    it "separates items without a sync_collection_id into ungrouped" do
      item1 = build_item(title: "Ungrouped Task", id: "u1")
      item2 = build_item(title: "Ungrouped Task", id: "u2")

      result = group_items_into_collections(ServiceA: [item1], ServiceB: [item2])

      expect(result[:collections].length).to eq(1)
      expect(result[:collections].first.title).to eq("Ungrouped Task")
    end
  end

  describe "grouping ungrouped items by title" do
    it "creates a SyncCollection for incomplete items with matching titles" do
      item1 = build_item(title: "Shared Task", id: "s1")
      item2 = build_item(title: "Shared Task", id: "s2")

      result = group_items_into_collections(ServiceA: [item1], ServiceB: [item2])

      expect(result[:collections].length).to eq(1)
      collection = result[:collections].first
      expect(collection.title).to eq("Shared Task")
      expect(item1.sync_collection_id).to eq(collection.id)
      expect(item2.sync_collection_id).to eq(collection.id)
    end

    it "stores newly grouped collections as item arrays in items_by_collection" do
      item1 = build_item(title: "Shared Task", id: "s1")
      item2 = build_item(title: "Shared Task", id: "s2")

      result = group_items_into_collections(ServiceA: [item1], ServiceB: [item2])

      collection = result[:collections].first
      expect(result[:items_by_collection][collection.id]).to contain_exactly(item1, item2)
    end

    it "does not create a collection for completed items" do
      item1 = build_item(title: "Done Task", id: "d1", completed: true)
      item2 = build_item(title: "Done Task", id: "d2", completed: true)

      result = group_items_into_collections(ServiceA: [item1], ServiceB: [item2])

      expect(result[:collections]).to be_empty
    end

    it "does not create a collection when item count exceeds number of services" do
      item1 = build_item(title: "Duped", id: "x1")
      item2 = build_item(title: "Duped", id: "x2")
      item3 = build_item(title: "Duped", id: "x3")

      # Only 2 services but 3 items with same title — skip
      result = group_items_into_collections(ServiceA: [item1], ServiceB: [item2, item3])

      expect(result[:collections]).to be_empty
    end

    it "does not create collections for singleton titles" do
      item_a = build_item(title: "Task Alpha", id: "a1")
      item_b = build_item(title: "Task Beta", id: "b1")

      result = group_items_into_collections(ServiceA: [item_a], ServiceB: [item_b])

      expect(result[:collections]).to be_empty
      expect(item_a.sync_collection_id).to be_nil
      expect(item_b.sync_collection_id).to be_nil
    end

    it "does not create a collection when duplicate titles come from the same provider" do
      item_a = build_item(title: "Inbox", id: "a1", provider: "GitHub")
      item_b = build_item(title: "Inbox", id: "a2", provider: "GitHub")

      result = group_items_into_collections(ServiceA: [item_a, item_b], ServiceB: [])

      expect(result[:collections]).to be_empty
      expect(item_a.sync_collection_id).to be_nil
      expect(item_b.sync_collection_id).to be_nil
    end

    it "creates a collection when matching titles appear across services" do
      item_a = build_item(title: "Shared Task", id: "a1")
      item_b = build_item(title: "Shared Task", id: "b1")
      item_c = build_item(title: "Different Task", id: "c1")

      result = group_items_into_collections(ServiceA: [item_a], ServiceB: [item_b, item_c])

      expect(result[:collections].length).to eq(1)
      expect(result[:collections].first.title).to eq("Shared Task")
      expect(item_a.sync_collection_id).to eq(result[:collections].first.id)
      expect(item_b.sync_collection_id).to eq(result[:collections].first.id)
      expect(item_c.sync_collection_id).to be_nil
    end

    it "returns empty collections when no items are provided" do
      result = group_items_into_collections(ServiceA: [], ServiceB: [])

      expect(result[:items_by_collection]).to be_empty
      expect(result[:collections]).to be_empty
    end
  end
end
