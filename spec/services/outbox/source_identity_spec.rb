# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SourceIdentity do
  let(:options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }

  def item_class(provider)
    stub_const("IdentitySpec#{provider.delete(':').capitalize}Item", Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end)
  end

  it "uses a permanent default instance segment for single-instance services" do
    item = item_class("Omnifocus").create!(options:, external_id: "of-1", url: "omnifocus:///task/of-1")

    expect(described_class.for(item)).to include(
      service_type: "omnifocus",
      service_instance: "omnifocus:default",
      external_id: "of-1",
      source_url: "omnifocus:///task/of-1"
    )
  end

  it "keeps the configured instance segment for named service instances" do
    item = item_class("Asana").create!(
      options: options.merge(service_name: "Asana:work"),
      external_id: "asana-1",
      source_external_id: "asana-1"
    )

    expect(described_class.for(item)).to include(
      service_type: "asana",
      service_instance: "asana:work",
      external_id: "asana-1"
    )
  end
end
