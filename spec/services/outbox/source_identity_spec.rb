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
      options: { services: [], primary: "Omnifocus", tags: [] },
      external_id: "task-77",
      url: "omnifocus:///task/task-77"
    )
  end

  let(:instanced_item_class) do
    stub_const("SourceIdentityInstancedSpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Github"
      end

      def external_data
        {}
      end
    end)
  end

  before do
    item_class
    instanced_item_class
  end

  it "appends the fixed default token for services without a configured instance" do
    expect(described_class.for(item)).to eq(
      service_type: "omnifocus",
      service_instance: "omnifocus:default",
      external_id: "task-77",
      source_url: "omnifocus:///task/task-77"
    )
  end

  it "keeps the configured instance segment for instanced services" do
    github_item = instanced_item_class.new(
      options: { services: [], primary: "Omnifocus", tags: [] },
      external_id: "issue-42",
      source_service_instance: "repo-1",
      source_service_name: "Github:repo-1"
    )

    expect(described_class.for(github_item)[:service_instance]).to eq("github:repo-1")
  end

  it "falls back to the external id and url when source columns were never captured" do
    item.external_id = "legacy-1"
    item.source_external_id = nil

    expect(described_class.for(item)).to include(external_id: "legacy-1")
  end
end
