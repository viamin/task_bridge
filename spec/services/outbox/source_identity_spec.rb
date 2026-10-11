# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SourceIdentity do
  let(:item_class) do
    stub_const("SourceIdentitySpecItem", Class.new(Base::SyncItem) do
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

  before { item_class }

  describe ".for" do
    # service_instance is embedded permanently in idempotency keys
    # (RDR #215; #222 clarification), so a service with no configured
    # instance suffix must still get a stable, non-blank token instead of
    # a bare service type.
    it "defaults service_instance to a fixed token when no instance is configured" do
      item = item_class.create!(title: "Buy milk", external_id: "1", options: { service_name: "Asana", services: [], primary: "Omnifocus", tags: [] })

      identity = described_class.for(item)

      expect(identity).to include(service_type: "asana", service_instance: "asana:default", external_id: "1")
    end

    it "uses the configured instance suffix instead of the default token when present" do
      item = item_class.create!(title: "Buy milk", external_id: "1", options: { service_name: "Asana:work", services: [], primary: "Omnifocus", tags: [] })

      identity = described_class.for(item)

      expect(identity).to include(service_type: "asana", service_instance: "asana:work")
    end

    it "prefers the source-recorded external id and url over the live attribute when both are present" do
      item = item_class.create!(
        title: "Buy milk",
        external_id: "1",
        url: "https://app.asana.com/0/1",
        options: { service_name: "Asana:work", services: [], primary: "Omnifocus", tags: [] }
      )

      identity = described_class.for(item)

      expect(identity).to include(external_id: "1", source_url: "https://app.asana.com/0/1")
    end
  end
end
