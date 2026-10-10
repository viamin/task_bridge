# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SourceIdentity do
  let(:item_class) do
    stub_const("SourceIdentitySpecItem", Class.new(Base::SyncItem) do
      attr_accessor :provider_name

      def self.attribute_map
        {}
      end

      def provider
        provider_name
      end

      def external_data
        {}
      end
    end)
  end

  def item_for(provider, source_service_instance: nil, external_id: "ext-1")
    item_class.new(provider_name: provider, source_service_instance:, external_id:)
  end

  before { item_class }

  describe ".for" do
    it "joins the service instance onto the service type for configured instances" do
      item = item_for("Asana", source_service_instance: "work")

      expect(described_class.for(item)).to include(
        service_type: "asana",
        service_instance: "asana:work",
        external_id: "ext-1"
      )
    end

    it "falls back to the permanent default token for single-instance services" do
      item = item_for("Omnifocus")

      expect(described_class.for(item)).to include(
        service_type: "omnifocus",
        service_instance: "omnifocus:default"
      )
    end

    it "prefers recorded source identity columns over transient attributes" do
      item = item_for("Github", source_service_instance: "repo-1", external_id: "ext-1")
      item.source_external_id = "recorded-9"
      item.source_url = "https://example.com/recorded-9"

      expect(described_class.for(item)).to include(
        external_id: "recorded-9",
        source_url: "https://example.com/recorded-9"
      )
    end
  end
end
