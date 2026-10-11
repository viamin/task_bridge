# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::BaselineSnapshots, :full_options do
  include ActiveSupport::Testing::TimeHelpers

  %w[Asana Omnifocus Github GoogleTasks].each do |provider_name|
    let(:"#{provider_name.underscore}_item_class") do
      stub_const("BaselineSnapshot#{provider_name}Item", Class.new(Base::SyncItem) do
        def self.attribute_map
          {}
        end

        define_method(:provider) { provider_name }

        def external_data
          {}
        end
      end)
    end
  end

  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }

  def create_item(klass, external_id:, title: "Buy milk", service_name: nil)
    item = klass.create!(
      options: service_name ? options.merge(service_name:) : options,
      title:,
      external_id:
    )
    travel_to(observed_at) { item.observe_source! }
    item
  end

  before do
    asana_item_class
    omnifocus_item_class
    github_item_class
    google_tasks_item_class
  end

  describe "#run! (representative services)" do
    it "emits a baseline item snapshot per service with provenance and no instance suffix for single-instance services" do
      asana_item = create_item(asana_item_class, external_id: "asana-1", service_name: "Asana:work")
      omnifocus_item = create_item(omnifocus_item_class, external_id: "of-1")
      github_item = create_item(github_item_class, external_id: "gh-1")
      google_item = create_item(google_tasks_item_class, external_id: "gt-1")

      summary = described_class.run!

      expect(summary[:enqueued]).to eq(4)
      expect(OutboxEntry.where(record_kind: "item").count).to eq(4)

      asana_row = OutboxEntry.find_by(record_kind: "item", external_id: "asana-1")
      expect(asana_row.service_type).to eq("asana")
      expect(asana_row.service_instance).to eq("asana:work")

      omnifocus_row = OutboxEntry.find_by(record_kind: "item", external_id: "of-1")
      expect(omnifocus_row.service_type).to eq("omnifocus")
      expect(omnifocus_row.service_instance).to eq("omnifocus:default")

      github_row = OutboxEntry.find_by(record_kind: "item", external_id: "gh-1")
      expect(github_row.payload).to include(
        "item_key" => github_item.item_key,
        "entity_type" => "task",
        "title" => "Buy milk",
        "status" => "open",
        "is_deleted" => false
      )
      expect(github_row.payload["provenance"]).to include("detected_by" => "backfill")
      expect(github_row.payload["provenance"]["backfilled_at"]).to be_present

      google_row = OutboxEntry.find_by(record_kind: "item", external_id: "gt-1")
      expect(google_row.service_type).to eq("google_tasks")
      expect(google_row.service_instance).to eq("google_tasks:default")

      [asana_item, omnifocus_item, github_item, google_item].each do |item|
        expect(OutboxEntry.find_by(record_kind: "item", external_id: item.external_id).observed_at)
          .to eq(item.last_observed_at)
      end
    end

    it "never emits a snapshot_seen observation row alongside the baseline item" do
      create_item(omnifocus_item_class, external_id: "of-1")

      described_class.run!

      expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    end
  end

  describe "idempotency" do
    it "can be run multiple times without duplicating or changing rows" do
      create_item(omnifocus_item_class, external_id: "of-1")

      first_summary = described_class.run!
      first_row = OutboxEntry.find_by(record_kind: "item", external_id: "of-1")

      second_summary = described_class.run!
      second_row = OutboxEntry.find_by(record_kind: "item", external_id: "of-1")

      expect(second_summary[:enqueued]).to eq(first_summary[:enqueued])
      expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
      expect(second_row.idempotency_key).to eq(first_row.idempotency_key)
      expect(second_row.payload).to eq(first_row.payload)
    end
  end

  describe "dry_run: true" do
    it "reports counts without writing any OutboxEntry rows" do
      create_item(omnifocus_item_class, external_id: "of-1")

      summary = described_class.run!(dry_run: true)

      expect(summary[:enqueued]).to eq(1)
      expect(OutboxEntry.count).to eq(0)
    end
  end

  describe "skipped records" do
    it "skips and counts items missing an external id or title" do
      omnifocus_item_class.create!(options:, title: "No external id")
      omnifocus_item_class.create!(options:, external_id: "of-no-title")

      summary = described_class.run!

      expect(summary[:skipped]["missing_external_id"]).to eq(1)
      expect(summary[:skipped]["missing_title"]).to eq(1)
      expect(OutboxEntry.where(record_kind: "item")).to be_empty
    end
  end

  describe "sync_collection confidence withholding" do
    let(:collection) { SyncCollection.create!(title: "Release checklist") }

    it "includes sync_collection on the item payload for medium/high confidence" do
      item = create_item(omnifocus_item_class, external_id: "of-1")
      item.update!(sync_collection: collection)
      collection.update_mapping_provenance!(method: "title_fallback", confidence: "medium")

      described_class.run!

      row = OutboxEntry.find_by(record_kind: "item", external_id: "of-1")
      expect(row.payload["sync_collection"]).to include(
        "sync_collection_id" => collection.id,
        "mapping_confidence" => "inferred"
      )
    end

    it "omits sync_collection on the item payload for low confidence" do
      item = create_item(omnifocus_item_class, external_id: "of-1")
      item.update!(sync_collection: collection)
      collection.update_mapping_provenance!(method: "manual_backfill", confidence: "low")

      described_class.run!

      row = OutboxEntry.find_by(record_kind: "item", external_id: "of-1")
      expect(row.payload).not_to have_key("sync_collection")
    end
  end
end
