# frozen_string_literal: true

require "spec_helper"
require "ostruct"

RSpec.describe Base::Service do
  let(:logger) do
    instance_double(
      StructuredLogger,
      sync_data_for: {},
      last_synced: last_synced_response,
      save_service_log!: nil
    )
  end
  let(:last_synced_response) { nil }
  let(:options) do
    {
      primary: "Primary",
      tags: ["Sync"],
      services: [],
      quiet: true,
      pretend: false,
      force: false,
      logger: logger,
      sync_started_at: Time.now,
      primary_service: nil
    }
  end
  let(:service_class) do
    Class.new(described_class) do
      def item_class
        Struct
      end

      def friendly_name
        "Dummy"
      end

      def sync_strategies
        [:from_primary]
      end

      def items_to_sync(tags: nil, inbox: true)
        @items_to_sync ||= []
      end

      def min_sync_interval
        60
      end
    end
  end
  let(:service) { service_class.new(options:) }

  describe "#should_sync?" do
    context "when the last sync timestamp is unknown" do
      let(:last_synced_response) { nil }

      it "returns true" do
        expect(service.should_sync?).to be true
      end
    end

    context "when forcing syncs" do
      let(:options) { super().merge(force: true) }

      it "returns true regardless of last sync time" do
        expect(service.should_sync?).to be true
      end
    end

    context "when within the minimum interval" do
      let(:last_synced_response) { 10 }

      it "returns false" do
        expect(service.should_sync?).to be false
      end
    end
  end

  describe "#update_sync_data" do
    let(:existing_item) do
      Class.new do
        attr_reader :updated_attributes

        def initialize
          @base_notes = "existing notes"
          @updated_attributes = {}
        end

        def sync_notes
          id = instance_variable_get(:@dummy_id)
          url = instance_variable_get(:@dummy_url)
          notes = [@base_notes]
          notes << "dummy_id: #{id}" if id
          notes << "dummy_url: #{url}" if url
          notes.join("\n")
        end

        def update_attributes(attributes)
          @updated_attributes = attributes
        end
      end.new
    end

    it "writes the sync metadata back to the item" do
      service.update_sync_data(existing_item, "abc123", "http://example.com")
      expect(existing_item.instance_variable_get(:@dummy_id)).to eq("abc123")
      expect(existing_item.instance_variable_get(:@dummy_url)).to eq("http://example.com")
      expect(existing_item.sync_notes).to include("dummy_id: abc123")
    end
  end

  describe "#skip_create?" do
    let(:external_task) { instance_double("ExternalTask") }

    it "skips create for completed items" do
      allow(external_task).to receive(:completed?).and_return(true)
      expect(service.skip_create?(external_task)).to be true
    end

    it "allows creation for incomplete items" do
      allow(external_task).to receive(:completed?).and_return(false)
      expect(service.skip_create?(external_task)).to be false
    end
  end

  describe "#existing_items" do
    let(:other_service) { instance_double("OtherService") }

    it "requests items with the service tag and inbox" do
      expect(other_service).to receive(:items_to_sync).with(tags: ["Dummy"], inbox: true).and_return(["item"])
      expect(service.existing_items(other_service)).to eq(["item"])
    end
  end

  describe "#should_sync? with item timestamps" do
    let(:last_synced_time) { Time.now - 2.minutes }

    it "compares the item timestamp to the last sync" do
      allow(logger).to receive(:last_synced).with("Dummy", interval: false).and_return(last_synced_time)
      expect(service.should_sync?(Time.now - 1.minute)).to be true
    end
  end

  describe "#sync_to_primary" do
    let(:primary_service) { instance_double("PrimaryService", friendly_name: "Primary", add_item: nil) }
    let(:service_item) do
      instance_double(
        "ServiceItem",
        find_matching_item_in: nil,
        completed?: false,
        updated_at: Time.now - 1.minute
      )
    end

    before do
      allow(service).to receive(:items_to_sync).with(tags: options[:tags]).and_return([service_item])
      allow(service).to receive(:existing_items).with(primary_service).and_return([])
      allow(logger).to receive(:last_synced).with("Dummy", interval: false).and_return(Time.now - 2.minutes)
    end

    it "adds service items to the primary service when needed" do
      expect(primary_service).to receive(:add_item).with(service_item)
      result = service.sync_to_primary(primary_service)
      expect(result["items_synced"]).to eq(1)
    end
  end
end
