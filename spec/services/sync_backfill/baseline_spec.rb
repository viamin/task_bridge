# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::Baseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:item_classes) do
    {
      omnifocus: sync_item_class("BaselineOmniFocusItem", "Omnifocus"),
      asana: sync_item_class("BaselineAsanaItem", "Asana"),
      github: sync_item_class("BaselineGithubItem", "Github"),
      google_tasks: sync_item_class("BaselineGoogleTasksItem", "GoogleTasks")
    }
  end

  before { item_classes }

  it "previews counts without writing local state" do
    collection = collection_with(item_classes.values, confidence: "low")

    result = described_class.run!(dry_run: true)

    expect(result.items_by_service).to eq(
      "asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1
    )
    expect(result.mappings_by_confidence).to eq(low_withheld: 4)
    expect(OutboxEntry).not_to exist
    expect(collection.reload.mapping_method).to eq("source_sync_id")
  end

  it "creates idempotent baseline snapshots and confirmed memberships" do
    collection_with(item_classes.values, confidence: "high")

    travel_to(observed_at) { 2.times { described_class.run! } }

    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty

    snapshot = OutboxEntry.find_by(record_kind: "item", service_type: "omnifocus")
    expect(snapshot.service_instance).to eq("omnifocus:default")
    expect(snapshot.payload).to include(
      "item_key" => "omnifocus:default:omni_focus_item-1",
      "observed_at" => observed_at.iso8601(6),
      "provenance" => include("detected_by" => "backfill", "backfilled_at" => observed_at.iso8601(6))
    )
  end

  def collection_with(classes, confidence:)
    collection = SyncCollection.create!(
      title: "Release checklist",
      mapping_method: "source_sync_id",
      mapping_confidence: confidence,
      mapping_last_observed_at: observed_at
    )
    classes.each do |item_class|
      item = item_class.create!(
        title: "Release checklist",
        external_id: "#{item_class.name.delete_prefix('Baseline').underscore}-1",
        sync_collection: collection,
        updated_at: observed_at,
        options: {
          service_name: item_class.provider_name,
          services: [],
          primary: "PrimaryService",
          tags: []
        }
      )
      item.update_columns(
        updated_at: observed_at,
        source_service_name: nil,
        source_service_instance: nil,
        source_service_type: nil,
        source_external_id: nil,
        source_url: nil,
        source_created_at: nil,
        source_updated_at: nil,
        first_observed_at: nil,
        last_observed_at: nil,
        source_metadata: nil
      )
    end
    collection
  end

  def sync_item_class(name, provider_name)
    stub_const(name, Class.new(Base::SyncItem) do
      class_attribute :provider_name, default: provider_name

      def self.attribute_map
        {}
      end

      def provider
        self.class.provider_name
      end

      def external_data
        {}
      end
    end)
  end
end
