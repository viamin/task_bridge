# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SourceIdentity do
  let(:item_class) do
    stub_const("SourceIdentitySpecItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def external_data
        {}
      end

      def provider
        @spec_provider
      end
    end)
  end

  def item_with(provider:, instance:, **attributes)
    item_class.new(attributes.merge(spec_provider: provider, source_service_instance: instance))
  end

  before { item_class }

  describe "service_instance" do
    it "appends the permanent default token for single-instance services" do
      identity = described_class.for(item_with(provider: "Omnifocus", instance: nil))

      expect(identity[:service_type]).to eq("omnifocus")
      expect(identity[:service_instance]).to eq("omnifocus:default")
    end

    it "keeps the configured instance segment when one exists" do
      identity = described_class.for(item_with(provider: "Asana", instance: "work"))

      expect(identity[:service_instance]).to eq("asana:work")
    end
  end

  describe "external ids and urls" do
    it "prefers source-persisted values over legacy columns" do
      identity = described_class.for(
        item_with(provider: "Github", instance: nil, external_id: "legacy-1",
                  source_external_id: "issue-42", source_url: "https://example.com/issue-42")
      )

      expect(identity[:external_id]).to eq("issue-42")
      expect(identity[:source_url]).to eq("https://example.com/issue-42")
    end

    it "falls back to the legacy external_id and url columns" do
      identity = described_class.for(
        item_with(provider: "Github", instance: nil, external_id: "legacy-1", url: "https://example.com/legacy-1")
      )

      expect(identity[:external_id]).to eq("legacy-1")
      expect(identity[:source_url]).to eq("https://example.com/legacy-1")
    end
  end
end
