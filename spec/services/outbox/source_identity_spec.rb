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
  let(:item) do
    item_class.new(
      external_id: "task-77",
      source_external_id: "task-77",
      source_service_instance:,
      source_url: "omnifocus:///task/task-77"
    )
  end

  before { item_class }

  context "with a configured instance suffix" do
    let(:source_service_instance) { "work" }

    it "keeps the configured instance segment" do
      expect(described_class.for(item)).to eq(
        service_type: "omnifocus",
        service_instance: "omnifocus:work",
        external_id: "task-77",
        source_url: "omnifocus:///task/task-77"
      )
    end
  end

  context "without a configured instance" do
    let(:source_service_instance) { nil }

    it "appends the permanent default instance segment" do
      expect(described_class.for(item)[:service_instance]).to eq("omnifocus:default")
    end
  end
end
