# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SourceIdentity do
  def item_class_for(provider)
    stub_const("SourceIdentity#{provider.delete(':').camelize}Item", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end).tap do |klass|
      klass.define_method(:provider) { provider }
    end
  end

  it "appends the permanent :default suffix for services without a configured instance" do
    item = item_class_for("Omnifocus").new(external_id: "of-1", url: "omnifocus:///task/of-1")

    expect(described_class.for(item)).to include(
      service_type: "omnifocus",
      service_instance: "omnifocus:default",
      external_id: "of-1",
      source_url: "omnifocus:///task/of-1"
    )
  end

  it "keeps a configured instance suffix unchanged" do
    item = item_class_for("Asana").new(
      external_id: "asana-9", source_service_instance: "work", source_external_id: "asana-9"
    )

    expect(described_class.for(item)).to include(service_type: "asana", service_instance: "asana:work")
  end

  it "does not double the suffix for an instance already named default" do
    item = item_class_for("Github").new(external_id: "issue-42", source_service_instance: "default")

    expect(described_class.for(item)).to include(service_instance: "github:default")
  end
end
