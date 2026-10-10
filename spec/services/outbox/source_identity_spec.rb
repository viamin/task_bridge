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

  before { item_class }

  def identity_for(**attributes)
    described_class.for(item_class.new(**attributes))
  end

  it "falls back to the permanent :default instance token for single-instance services" do
    expect(identity_for(external_id: "task-77").fetch(:service_instance)).to eq("test_service:default")
  end

  it "keeps the captured instance segment for multi-instance services" do
    item = item_class.new(external_id: "1201", source_service_instance: "work")

    expect(described_class.for(item)).to include(
      service_type: "test_service",
      service_instance: "test_service:work",
      external_id: "1201"
    )
  end

  it "prefers the captured source identity over the live attributes" do
    expect(identity_for(external_id: "live-1", source_external_id: "source-1", url: "https://live",
                        source_url: "https://source")).to include(
                          external_id: "source-1",
                          source_url: "https://source"
                        )
  end

  it "falls back to the live external id and url when no source identity was captured" do
    expect(identity_for(external_id: "live-1", url: "https://live")).to include(
      external_id: "live-1",
      source_url: "https://live"
    )
  end
end
