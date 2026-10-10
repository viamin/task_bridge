# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SourceIdentity do
  let(:omnifocus_class) do
    stub_const("SourceIdentityOmnifocusItem", Class.new(Base::SyncItem) do
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
  let(:asana_class) do
    stub_const("SourceIdentityAsanaItem", Class.new(Base::SyncItem) do
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
  let(:item_options) { { services: [], primary: "Omnifocus", tags: [] } }

  before do
    omnifocus_class
    asana_class
  end

  describe ".for" do
    it "builds the identity from the service type and a configured instance" do
      item = asana_class.create!(
        external_id: "asana-1",
        notes: "",
        options: item_options.merge(service_name: "Asana:work")
      )

      expect(described_class.for(item)).to eq(
        service_type: "asana",
        service_instance: "asana:work",
        external_id: "asana-1",
        source_url: nil
      )
    end

    it "falls back to the permanent <service_type>:default instance for single-instance services" do
      item = omnifocus_class.create!(
        external_id: "of-1",
        url: "omnifocus:///task/of-1",
        notes: "",
        options: item_options.merge(service_name: "Omnifocus")
      )

      expect(described_class.for(item)).to eq(
        service_type: "omnifocus",
        service_instance: "omnifocus:default",
        external_id: "of-1",
        source_url: "omnifocus:///task/of-1"
      )
    end

    it "prefers captured source identity columns when present" do
      item = omnifocus_class.create!(
        external_id: "of-1",
        notes: "",
        options: item_options.merge(service_name: "Omnifocus")
      )
      item.source_service_instance = "personal"
      item.source_external_id = "legacy-9"
      item.source_url = "https://example.com/legacy-9"

      identity = described_class.for(item)

      expect(identity[:service_instance]).to eq("omnifocus:personal")
      expect(identity[:external_id]).to eq("legacy-9")
      expect(identity[:source_url]).to eq("https://example.com/legacy-9")
    end
  end
end
