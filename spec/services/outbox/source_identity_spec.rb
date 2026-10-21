# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SourceIdentity do
  def item_class(constant_name, provider)
    stub_const(constant_name, Class.new(Base::SyncItem) do
      define_singleton_method(:attribute_map) { {} }

      define_method(:provider) { provider }
      define_method(:external_data) { {} }
    end)
  end

  let(:asana_class) { item_class("SourceIdentitySpecAsanaItem", "Asana") }
  let(:github_class) { item_class("SourceIdentitySpecGithubItem", "Github") }

  before do
    asana_class
    github_class
  end

  def asana_item(service_name)
    asana_class.create!(title: "Buy milk", external_id: "asana-1", source_service_name: service_name)
  end

  describe ".for_backfill" do
    # #222 baselines must correlate with every live row the observation and
    # mapping emitters publish for the same item, so the backfill never mints
    # a backfill-only identity: it publishes exactly what `.for` resolves to.
    it "publishes the identity the live path already uses" do
      item = asana_item("Asana")

      expect(described_class.for_backfill(item)).to eq(described_class.for(item))
      expect(described_class.for_backfill(item)).to include(service_type: "asana", service_instance: "asana")
    end

    it "keeps an instance the item already carries" do
      item = asana_item("Asana:work")

      expect(described_class.for_backfill(item)).to eq(described_class.for(item))
      expect(described_class.for_backfill(item)).to include(service_type: "asana", service_instance: "asana:work")
    end

    it "canonicalizes legacy double-camel class names (#222)" do
      item = github_class.create!(title: "Buy milk", external_id: "issue-1", source_service_name: "GitHub:repo-1")

      expect(described_class.for_backfill(item))
        .to include(service_type: "github", service_instance: "github:repo-1")
    end
  end

  describe ".canonical_service_type" do
    it "maps legacy class-name spellings onto one canonical service type" do
      expect(described_class.canonical_service_type("GitHub")).to eq("github")
      expect(described_class.canonical_service_type("OmniFocus")).to eq("omnifocus")
    end

    it "passes already-canonical spellings through unchanged" do
      expect(described_class.canonical_service_type("Github")).to eq("github")
      expect(described_class.canonical_service_type("Omnifocus")).to eq("omnifocus")
    end
  end
end
