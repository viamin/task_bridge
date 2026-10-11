# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::Backfill do
  let(:now) { Time.zone.parse("2026-10-11T12:00:00Z") }
  let(:item_classes) do
    {
      asana: backfill_item_class("BackfillAsanaItem", "Asana"),
      github: backfill_item_class("BackfillGithubItem", "Github"),
      google_tasks: backfill_item_class("BackfillGoogleTasksItem", "Google Tasks"),
      omnifocus: backfill_item_class("BackfillOmnifocusItem", "Omnifocus")
    }
  end

  before { item_classes }

  it "backfills representative source snapshots and only publishable mappings idempotently" do
    high_collection = SyncCollection.create!(title: "Release", mapping_method: "source_sync_id", mapping_confidence: "high")
    low_collection = SyncCollection.create!(title: "Errands", mapping_method: "manual_backfill", mapping_confidence: "low")
    asana = create_item(:asana, "asana-1", high_collection)
    github = create_item(:github, "github-1", high_collection)
    google_tasks = create_item(:google_tasks, "google-1", low_collection)
    omnifocus = create_item(:omnifocus, "omnifocus-1", low_collection)

    summary = described_class.run!(now:)

    expect(summary).to include(
      items_by_service: { "asana" => 1, "github" => 1, "google_tasks" => 1, "omnifocus" => 1 },
      mappings_by_confidence: { "high" => 2, "low" => 2 }
    )
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).to contain_exactly("asana-1", "github-1")
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty

    item_rows = OutboxEntry.where(record_kind: "item")
    expect(item_rows.map(&:service_instance)).to contain_exactly(
      "asana:default", "github:default", "google_tasks:default", "omnifocus:default"
    )
    expect(item_rows.map { |row| row.payload.dig("provenance", "detected_by") }).to all(eq("backfill"))
    expect([asana, github, google_tasks, omnifocus].map { |item| item.reload.last_snapshot }).to all(be_present)

    expect { described_class.run!(now:) }.not_to(change { OutboxEntry.count })
  end

  it "reports incomplete records without writing local provenance or outbox rows in dry-run mode" do
    item = item_classes.fetch(:asana).create!(title: "Incomplete")
    item.update_columns(source_service_name: nil, source_service_instance: nil, source_service_type: nil)

    summary = described_class.run!(dry_run: true, now:)

    expect(summary[:skipped_or_incomplete]).to include("missing external ID (Asana)" => 1)
    expect(item.reload.source_service_name).to be_nil
    expect(OutboxEntry.count).to eq(0)
  end

  def create_item(service, external_id, collection)
    item_classes.fetch(service).create!(
      title: "#{service} task",
      external_id:,
      sync_collection: collection,
      options: { service_name: item_classes.fetch(service).provider_name, services: [], primary: "Asana", tags: [] }
    )
  end

  def backfill_item_class(class_name, provider_name)
    stub_const(class_name, Class.new(Base::SyncItem) do
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
