# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SourceIdentity do
  let(:item_class) do
    stub_const("SourceIdentitySpecItem", Class.new(Base::SyncItem) do
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
  let(:options) { { services: [], primary: "Omnifocus", tags: [] } }

  before { item_class }

  it "appends the permanent default instance token when no instance is configured" do
    item = item_class.create!(title: "Buy milk", external_id: "t-1", options:)

    expect(described_class.for(item)).to include(
      service_type: "test_service",
      service_instance: "test_service:default",
      external_id: "t-1"
    )
  end

  it "keeps the configured instance suffix when one exists" do
    item = item_class.create!(
      title: "Buy milk",
      external_id: "t-2",
      options: options.merge(service_name: "TestService:work")
    )

    expect(described_class.for(item)).to include(
      service_type: "test_service",
      service_instance: "test_service:work"
    )
  end

  it "prefers captured source identity columns over legacy columns" do
    item = item_class.create!(title: "Buy milk", external_id: "legacy-1", url: "https://legacy.example", options:)
    item.update_columns(source_external_id: "src-1", source_url: "https://src.example")

    expect(described_class.for(item)).to include(
      external_id: "src-1",
      source_url: "https://src.example"
    )
  end
end
