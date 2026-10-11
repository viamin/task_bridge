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
  let(:item) { item_class.new(external_id: "of-1", options: { services: [], primary: "Omnifocus", tags: [] }) }

  before { item_class }

  it "appends the permanent default token for single-instance services" do
    expect(described_class.for(item)).to eq(
      service_type: "omnifocus",
      service_instance: "omnifocus:default",
      external_id: "of-1",
      source_url: nil
    )
  end

  it "keeps the configured instance segment for instanced services" do
    item.source_service_instance = "work"

    expect(described_class.for(item)[:service_instance]).to eq("omnifocus:work")
  end

  it "prefers captured source identity columns over adapter attributes" do
    item.assign_attributes(external_id: "legacy-1", url: "https://example.test/legacy")

    expect(described_class.for(item)).to include(external_id: "legacy-1", source_url: "https://example.test/legacy")

    item.assign_attributes(source_external_id: "of-1", source_url: "omnifocus:///task/of-1")

    expect(described_class.for(item)).to include(external_id: "of-1", source_url: "omnifocus:///task/of-1")
  end
end
