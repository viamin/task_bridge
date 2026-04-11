# frozen_string_literal: true

require "rails_helper"

RSpec.describe Base::Service do
  let(:logger) { instance_double(StructuredLogger, sync_data_for: {}, last_synced: last_sync) }
  let(:last_sync) { Time.current - 5.minutes }
  let(:sync_item_class) do
    stub_const("BaseServiceSpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "TestService"
      end

      def external_data
        {}
      end
    end)
  end
  let(:primary_sync_item_class) do
    stub_const("PrimaryServiceSpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "PrimaryService"
      end

      def external_data
        {}
      end
    end)
  end
  let(:service_class) do
    Class.new(described_class) do
      def friendly_name
        "Test Service"
      end

      def item_class
        BaseServiceSpecItem
      end

      def sync_strategies
        [:to_primary]
      end

      def items_to_sync(*, **)
        @items_to_sync || []
      end

      def add_item(*)
        nil
      end

      def min_sync_interval
        60
      end
    end
  end
  let(:service) { service_class.new(options: options) }
  let(:options) do
    {
      logger:,
      quiet: true,
      pretend: false,
      verbose: false,
      debug: false,
      primary: "Asana",
      services: [],
      tags: ["work"]
    }
  end
  let(:primary_service) { double("PrimaryService", friendly_name: "Primary Service", update_item: nil, items_to_sync: [existing_item]) }
  let(:existing_item) { instance_double(Base::SyncItem) }
  let(:service_item) do
    instance_double(
      Base::SyncItem,
      last_modified: service_last_modified,
      updated_at: service_updated_at,
      find_matching_item_in: existing_item,
      completed?: false,
      title: "Synced task"
    )
  end
  let(:service_last_modified) { Time.current - 1.minute }
  let(:service_updated_at) { Time.current - 2.hours }

  before do
    sync_item_class
    primary_sync_item_class
  end

  describe "#sync_to_primary" do
    before do
      allow(service).to receive(:items_to_sync).and_return([service_item])
      allow(service).to receive(:should_sync?).with(no_args).and_return(true)
      allow(service).to receive(:should_sync?).with(service_last_modified).and_return(true)
      allow(service).to receive(:existing_items).with(primary_service).and_return([existing_item])
      allow(primary_service).to receive(:update_item)
    end

    it "checks sync freshness using last_modified instead of ActiveRecord updated_at" do
      service.sync_to_primary(primary_service)

      expect(service).to have_received(:should_sync?).with(service_last_modified)
      expect(primary_service).to have_received(:update_item).with(existing_item, service_item)
    end

    it "loads existing primary items once per sync run" do
      service.sync_to_primary(primary_service)

      expect(service).to have_received(:existing_items).with(primary_service).once
      expect(service_item).to have_received(:find_matching_item_in).with([existing_item]).once
    end

    it "persists a sync collection for matched items that sync successfully" do
      persisted_service_item = sync_item_class.create!(
        title: "Persisted service task",
        external_id: "service-123",
        completed: false,
        last_modified: Time.current - 1.minute
      )
      persisted_primary_item = primary_sync_item_class.create!(
        title: "Persisted primary task",
        external_id: "primary-123",
        completed: false,
        last_modified: Time.current - 2.minutes
      )

      allow(service).to receive(:items_to_sync).and_return([persisted_service_item])
      allow(service).to receive(:should_sync?).with(persisted_service_item.last_modified).and_return(true)
      allow(service).to receive(:existing_items).with(primary_service).and_return([persisted_primary_item])
      allow(persisted_service_item).to receive(:find_matching_item_in).with([persisted_primary_item]).and_return(persisted_primary_item)

      expect do
        service.sync_to_primary(primary_service)
      end.to change(SyncCollection, :count).by(1)

      expect(persisted_service_item.reload.sync_collection_id).to eq(persisted_primary_item.reload.sync_collection_id)
      expect(persisted_service_item.sync_collection_id).to be_present
    end

    it "persists a sync collection for matched items even when the item is skipped as unchanged" do
      persisted_service_item = sync_item_class.create!(
        title: "Unchanged service task",
        external_id: "service-unchanged-123",
        completed: false,
        last_modified: Time.current - 2.minutes
      )
      persisted_primary_item = primary_sync_item_class.create!(
        title: "Unchanged primary task",
        external_id: "primary-unchanged-123",
        completed: false,
        last_modified: Time.current - 3.minutes
      )

      allow(service).to receive(:items_to_sync).and_return([persisted_service_item])
      allow(service).to receive(:should_sync?).with(persisted_service_item.last_modified).and_return(false)
      allow(service).to receive(:existing_items).with(primary_service).and_return([persisted_primary_item])
      allow(persisted_service_item).to receive(:find_matching_item_in).with([persisted_primary_item]).and_return(persisted_primary_item)

      expect do
        result = service.sync_to_primary(primary_service)
        expect(result["touched_collection_ids"]).to eq([])
      end.to change(SyncCollection, :count).by(1)

      expect(primary_service).not_to have_received(:update_item)
      expect(persisted_service_item.reload.sync_collection_id).to eq(persisted_primary_item.reload.sync_collection_id)
    end

    it "persists a sync collection for newly created primary items" do
      persisted_service_item = sync_item_class.create!(
        title: "Newly created primary task",
        external_id: "service-create-123",
        completed: false,
        last_modified: Time.current - 1.minute
      )

      allow(service).to receive(:items_to_sync).and_return([persisted_service_item])
      allow(service).to receive(:should_sync?).with(persisted_service_item.last_modified).and_return(true)
      allow(service).to receive(:existing_items).with(primary_service).and_return([])
      allow(persisted_service_item).to receive(:find_matching_item_in).with([]).and_return(nil)
      allow(primary_service).to receive(:item_class).and_return(primary_sync_item_class)
      allow(primary_service).to receive(:add_item) do
        persisted_service_item.define_singleton_method(:primary_service_id) { "primary-create-123" }
        persisted_service_item.define_singleton_method(:primary_service_url) { "https://example.test/tasks/primary-create-123" }
      end

      expect do
        service.sync_to_primary(primary_service)
      end.to change(SyncCollection, :count).by(1)

      created_primary_item = primary_sync_item_class.find_by!(external_id: "primary-create-123")
      expect(persisted_service_item.reload.sync_collection_id).to eq(created_primary_item.sync_collection_id)
      expect(created_primary_item.title).to eq(persisted_service_item.title)
    end

    it "does not mark a collection as touched when the provider update returns a failure message" do
      persisted_service_item = sync_item_class.create!(
        title: "Provider failure service task",
        external_id: "service-failure-123",
        completed: false,
        last_modified: Time.current - 1.minute
      )
      persisted_primary_item = primary_sync_item_class.create!(
        title: "Provider failure primary task",
        external_id: "primary-failure-123",
        completed: false,
        last_modified: Time.current - 2.minutes
      )

      allow(service).to receive(:items_to_sync).and_return([persisted_service_item])
      allow(service).to receive(:should_sync?).with(persisted_service_item.last_modified).and_return(true)
      allow(service).to receive(:existing_items).with(primary_service).and_return([persisted_primary_item])
      allow(persisted_service_item).to receive(:find_matching_item_in).with([persisted_primary_item]).and_return(persisted_primary_item)
      allow(primary_service).to receive(:update_item).with(persisted_primary_item, persisted_service_item).and_return("Failed to update item")

      expect do
        result = service.sync_to_primary(primary_service)
        expect(result["touched_collection_ids"]).to eq([])
      end.not_to change(SyncCollection, :count)
    end

    it "skips sync collection persistence when items are already in different collections" do
      first_collection = SyncCollection.create!(title: "Service collection")
      second_collection = SyncCollection.create!(title: "Primary collection")
      persisted_service_item = sync_item_class.create!(
        title: "Persisted service task",
        external_id: "service-merge-123",
        completed: false,
        last_modified: Time.current - 1.minute,
        sync_collection_id: first_collection.id
      )
      persisted_primary_item = primary_sync_item_class.create!(
        title: "Persisted primary task",
        external_id: "primary-merge-123",
        completed: false,
        last_modified: Time.current - 2.minutes,
        sync_collection_id: second_collection.id
      )

      expect do
        service.send(:persist_sync_collection_for, persisted_primary_item, persisted_service_item)
      end.not_to raise_error

      expect(persisted_service_item.reload.sync_collection).to eq(first_collection)
      expect(persisted_primary_item.reload.sync_collection).to eq(second_collection)
    end
  end

  describe "#sync_from_primary" do
    it "persists a sync collection for newly created service items" do
      primary_item = primary_sync_item_class.create!(
        title: "Newly created service task",
        external_id: "primary-create-456",
        completed: false,
        last_modified: Time.current - 1.minute
      )

      allow(primary_service).to receive(:items_to_sync).with(tags: ["Test Service"]).and_return([primary_item])
      allow(service).to receive(:items_to_sync).and_return([])
      allow(service).to receive(:add_item) do
        primary_item.define_singleton_method(:test_service_id) { "service-create-456" }
        primary_item.define_singleton_method(:test_service_url) { "https://example.test/tasks/service-create-456" }
      end
      allow(primary_item).to receive(:find_matching_item_in).with([]).and_return(nil)

      expect do
        service.sync_from_primary(primary_service)
      end.to change(SyncCollection, :count).by(1)

      created_service_item = sync_item_class.find_by!(external_id: "service-create-456")
      expect(primary_item.reload.sync_collection_id).to eq(created_service_item.sync_collection_id)
      expect(created_service_item.title).to eq(primary_item.title)
    end
  end

  describe "#should_sync?" do
    it "uses ActiveRecord-backed sync state instead of the structured log file" do
      SyncServiceState.create!(
        service_name: service.friendly_name,
        last_successful_at: Time.current - 5.minutes
      )
      allow(logger).to receive(:last_synced).and_return(nil)

      expect(service.should_sync?(Time.current - 1.minute)).to be true
    end

    it "skips syncing unchanged items when the service state is newer than the item" do
      SyncServiceState.create!(
        service_name: service.friendly_name,
        last_successful_at: Time.current - 30.seconds
      )

      expect(service.should_sync?(Time.current - 1.minute)).to be false
    end

    it "uses the fallback logger timestamp when deciding whether an item changed" do
      last_sync_time = Time.current - 30.seconds
      allow(logger).to receive(:last_synced).with(service.friendly_name).and_return(last_sync_time)

      expect(service.should_sync?(Time.current - 1.minute)).to be false
      expect(service.should_sync?(Time.current - 10.seconds)).to be true
    end
  end

  describe "#paired_items" do
    let(:primary_item) { instance_double(Base::SyncItem, last_modified: Time.current - 10.minutes, updated_at: Time.current - 1.minute) }
    let(:matching_item) { instance_double(Base::SyncItem, last_modified: Time.current - 2.minutes, updated_at: Time.current - 20.minutes) }

    before do
      allow(primary_item).to receive(:find_matching_item_in).and_return(matching_item)
      allow(matching_item).to receive(:find_matching_item_in).and_return(primary_item)
    end

    it "orders matched pairs using last_modified before falling back to updated_at" do
      paired_items = service.send(:paired_items, [primary_item], [matching_item]).to_a

      expect(paired_items).to eq([[primary_item, matching_item]])
    end

    it "handles items with nil last_modified and nil updated_at without crashing" do
      nil_timestamp_item = instance_double(Base::SyncItem, last_modified: nil, updated_at: nil)
      other_item = instance_double(Base::SyncItem, last_modified: Time.current - 5.minutes, updated_at: Time.current - 1.hour)

      allow(nil_timestamp_item).to receive(:find_matching_item_in).and_return(other_item)
      allow(other_item).to receive(:find_matching_item_in).and_return(nil)

      expect { service.send(:paired_items, [nil_timestamp_item], []) }.not_to raise_error
    end
  end
end
