# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SourceIdentity, :full_options do
  it "uses a permanent default token for services without configured instances" do
    item_class = stub_const("DefaultInstanceItem", Class.new(Base::SyncItem) do
      def self.attribute_map = {}

      def provider = "Omnifocus"

      def external_data = {}
    end)
    item = item_class.new(options: options.merge(service_name: "Omnifocus"), external_id: "of-1")

    expect(described_class.for(item)).to include(service_type: "omnifocus", service_instance: "omnifocus:default")
  end
end
