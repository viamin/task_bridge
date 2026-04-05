# frozen_string_literal: true

require "rails_helper"

RSpec.describe Base::Service do
  let(:logger) { instance_double(StructuredLogger, sync_data_for: {}, last_synced: last_sync) }
  let(:last_sync) { Time.current - 5.minutes }
  let(:service_class) do
    Class.new(described_class) do
      def friendly_name
        "Test Service"
      end

      def item_class
        Base::SyncItem
      end

      def sync_strategies
        [:to_primary]
      end

      def items_to_sync(*, **)
        @items_to_sync || []
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
  end
end
