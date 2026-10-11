# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SourceIdentity do
  let(:item_class) do
    stub_const("SourceIdentitySpecItem", Class.new(Base::SyncItem) do
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
  let(:base_options) { { services: [], primary: "Asana", tags: [] } }

  before { item_class }

  describe ".for" do
    it "appends the permanent default instance token when no instance is configured" do
      item = item_class.create!(external_id: "task-1", options: base_options.merge(service_name: "Asana"))

      expect(described_class.for(item)).to include(service_type: "asana", service_instance: "asana:default")
    end

    it "embeds the configured instance segment when present" do
      item = item_class.create!(external_id: "task-1", options: base_options.merge(service_name: "Asana:work-12345"))

      expect(described_class.for(item)).to include(service_type: "asana", service_instance: "asana:work-12345")
    end

    it "falls back to the local external_id and url when source identity has not been captured" do
      item = item_class.create!(title: "Buy milk", external_id: "task-1", url: "https://example.com/task-1",
                                options: base_options.merge(service_name: "Asana"))
      item.update_columns(source_external_id: nil, source_url: nil)

      identity = described_class.for(item)

      expect(identity[:external_id]).to eq("task-1")
      expect(identity[:source_url]).to eq("https://example.com/task-1")
    end
  end
end
