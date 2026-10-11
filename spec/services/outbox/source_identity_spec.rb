# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SourceIdentity do
  let(:item_class) do
    stub_const("SourceIdentitySpecItem", Class.new(Base::SyncItem) do
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
  let(:base_attributes) do
    { title: "Ship it", external_id: "issue-42", url: "https://github.com/org/repo/issues/42" }
  end

  before { item_class }

  def identity_for(**overrides)
    described_class.for(item_class.new(base_attributes.merge(overrides)))
  end

  it "falls back to the permanent :default instance token for single-instance services" do
    expect(identity_for(source_service_instance: nil)).to include(
      service_type: "github",
      service_instance: "github:default",
      external_id: "issue-42",
      source_url: "https://github.com/org/repo/issues/42"
    )
  end

  it "keeps the configured instance segment for multi-instance services" do
    expect(identity_for(source_service_instance: "repo-1")[:service_instance]).to eq("github:repo-1")
  end

  it "prefers persisted source provenance columns over the raw attributes" do
    expect(identity_for(source_external_id: "source-id", source_url: "https://source.example/42")).to include(
      external_id: "source-id",
      source_url: "https://source.example/42"
    )
  end
end
