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
    it "defaults service_instance to a stable token for a source with no configured instance" do
      item = item_class.create!(
        options: { service_name: "Omnifocus", services: [], primary: "Omnifocus", tags: [] },
        external_id: "of-1"
      )

      expect(described_class.for(item)).to include(service_type: "omnifocus", service_instance: "omnifocus:default")
    end

    it "preserves an explicit configured service instance" do
      item = item_class.create!(
        options: { service_name: "Omnifocus:work", services: [], primary: "Omnifocus", tags: [] },
        external_id: "of-2"
      )

      expect(described_class.for(item)).to include(service_type: "omnifocus", service_instance: "omnifocus:work")
    end
  end
end
