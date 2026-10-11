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

  before { item_class }

  describe ".for" do
    it "appends a permanent default token when no service instance is configured" do
      item = item_class.create!(title: "Buy milk", external_id: "task-1", source_service_name: "Omnifocus")

      identity = described_class.for(item)

      expect(identity[:service_type]).to eq("omnifocus")
      expect(identity[:service_instance]).to eq("omnifocus:default")
    end

    it "uses the configured instance name instead of the default token when present" do
      item = item_class.create!(title: "Buy milk", external_id: "task-1", source_service_name: "Omnifocus:work")

      identity = described_class.for(item)

      expect(identity[:service_instance]).to eq("omnifocus:work")
    end
  end
end
