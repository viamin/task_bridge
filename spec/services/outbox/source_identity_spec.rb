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
  let(:source_service_instance) { nil }
  let(:item) do
    item_class.new(
      title: "Buy milk",
      external_id: "of-1",
      url: "omnifocus:///task/of-1",
      source_service_instance:
    )
  end

  before { item_class }

  it "falls back to the permanent default token when no instance is configured" do
    expect(described_class.for(item)).to include(
      service_type: "omnifocus",
      service_instance: "omnifocus:default",
      external_id: "of-1",
      source_url: "omnifocus:///task/of-1"
    )
  end

  it "keeps the configured instance suffix when one exists" do
    item.source_service_instance = "work"

    expect(described_class.for(item)).to include(
      service_type: "omnifocus",
      service_instance: "omnifocus:work"
    )
  end

  it "prefers captured source provenance over the live attributes" do
    item.source_external_id = "of-captured"
    item.source_url = "https://example.test/of-captured"

    expect(described_class.for(item)).to include(
      external_id: "of-captured",
      source_url: "https://example.test/of-captured"
    )
  end
end
