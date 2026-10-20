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
  let(:omnifocus_class) { item_class("SourceIdentitySpecOmnifocusItem", "Omnifocus") }

  before do
    asana_class
    github_class
    omnifocus_class
  end

  def asana_item(service_name)
    asana_class.create!(title: "Buy milk", external_id: "asana-1", source_service_name: service_name)
  end

  describe ".for_backfill" do
    it "qualifies an unqualified service instance as the default instance" do
      expect(described_class.for_backfill(asana_item("Asana")))
        .to include(service_type: "asana", service_instance: "asana:default")
    end

    it "keeps an instance the item already carries" do
      expect(described_class.for_backfill(asana_item("Asana:work")))
        .to include(service_type: "asana", service_instance: "asana:work")
    end

    it "canonicalizes legacy double-camel class names (#222)" do
      item = github_class.create!(title: "Buy milk", external_id: "issue-1", source_service_name: "GitHub:repo-1")

      expect(described_class.for_backfill(item))
        .to include(service_type: "github", service_instance: "github:repo-1")
    end

    it "builds an item key from the qualified identity it publishes" do
      item = omnifocus_class.create!(title: "Buy milk", external_id: "of-1", source_service_name: "Omnifocus")

      expect(described_class.item_key(described_class.for_backfill(item))).to eq("omnifocus:default:of-1")
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
