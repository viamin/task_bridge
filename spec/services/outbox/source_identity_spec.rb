# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SourceIdentity do
  let(:item_class) do
    stub_const("SourceIdentitySpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Omnifocus"
      end

      def external_data
        {}
      end
    end)
  end
  let(:asana_item_class) do
    stub_const("SourceIdentitySpecAsanaItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Asana"
      end

      def external_data
        {}
      end
    end)
  end

  before do
    item_class
    asana_item_class
  end

  describe ".for" do
    it "appends the permanent default token when no instance segment was captured" do
      item = item_class.new(external_id: "task-77")

      expect(described_class.for(item)).to eq(
        service_type: "omnifocus",
        service_instance: "omnifocus:default",
        external_id: "task-77",
        source_url: nil
      )
    end

    it "keeps a captured instance segment next to the service type" do
      item = asana_item_class.new(external_id: "1201", source_service_instance: "work")

      expect(described_class.for(item)[:service_instance]).to eq("asana:work")
    end

    it "prefers the captured provenance identity fields" do
      item = item_class.new(
        external_id: "stale",
        source_external_id: "task-77",
        url: "https://example.com/stale",
        source_url: "omnifocus:///task/task-77"
      )

      expect(described_class.for(item)).to include(
        external_id: "task-77",
        source_url: "omnifocus:///task/task-77"
      )
    end
  end
end
