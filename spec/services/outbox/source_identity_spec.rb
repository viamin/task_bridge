# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SourceIdentity do
  let(:item_class) do
    stub_const("IdentitySpecItem", Class.new(Base::SyncItem) do
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
  let(:github_item_class) do
    stub_const("IdentityGithubSpecItem", Class.new(Base::SyncItem) do
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
  let(:options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }

  before do
    item_class
    github_item_class
  end

  it "resolves instance-less services to the permanent default token" do
    item = item_class.create!(options:, external_id: "asana-1")

    expect(described_class.for(item)).to eq(
      service_type: "asana",
      service_instance: "asana:default",
      external_id: "asana-1",
      source_url: nil
    )
  end

  it "keeps the configured instance and appends the default token" do
    item = item_class.create!(options: options.merge(service_name: "Asana:work"), external_id: "asana-1")

    expect(described_class.for(item)[:service_instance]).to eq("asana:work:default")
  end

  it "prefers captured source identity over live attributes" do
    item = item_class.create!(options:, external_id: "asana-1", url: "https://live.example.com/asana-1")
    item.update_columns(source_external_id: "asana-source-1", source_url: "https://source.example.com/asana-source-1")

    identity = described_class.for(item)
    expect(identity[:external_id]).to eq("asana-source-1")
    expect(identity[:source_url]).to eq("https://source.example.com/asana-source-1")
  end

  it "uses the same identity shape for instanced services of other providers" do
    item = github_item_class.create!(options: options.merge(service_name: "Github:repo-1"), external_id: "issue-42")

    expect(described_class.for(item)[:service_instance]).to eq("github:repo-1:default")
  end
end
