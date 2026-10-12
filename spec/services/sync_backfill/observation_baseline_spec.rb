# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncBackfill::ObservationBaseline, :full_options do
  let(:output) { StringIO.new }
  let(:collection_time) { Time.zone.parse("2026-01-02T03:04:05Z") }
  let(:omnifocus_item_class) { sync_item_class("BackfillOmnifocusTask", "Omnifocus") }
  let(:asana_item_class) { sync_item_class("BackfillAsanaTask", "Asana") }
  let(:github_item_class) { sync_item_class("BackfillGithubTask", "Github") }
  let(:google_tasks_item_class) { sync_item_class("BackfillGoogleTasksTask", "GoogleTasks") }

  it "backfills representative source snapshots and withholds low-confidence mappings idempotently" do
    items = [
      item_for(omnifocus_item_class, "omnifocus-1", "high"),
      item_for(asana_item_class, "asana-1", "high"),
      item_for(github_item_class, "github-1", "medium"),
      item_for(google_tasks_item_class, "google-tasks-1", "low")
    ]

    result = described_class.run!(output:)

    expect(result).to include(items: 4, mappings: 3)
    expect(result[:skipped]).to include(low_confidence_mapping: 1)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(3)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.find_by(external_id: "omnifocus-1").service_instance).to eq("omnifocus:default")
    expect(OutboxEntry.find_by(external_id: "github-1", record_kind: "mapping").payload)
      .to include("mapping_confidence" => "inferred")
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)

    expect { described_class.run!(output:) }.not_to change(OutboxEntry, :count)
  end

  it "reports a read-only preview with incomplete and low-confidence records" do
    item_for(omnifocus_item_class, nil, "low")

    result = described_class.run!(dry_run: true, output:)

    expect(result).to include(dry_run: true, items: 0, mappings: 0)
    expect(result[:skipped]).to include(incomplete_item: 1, low_confidence_mapping: 1)
    expect(OutboxEntry.all).to be_empty
    expect(JSON.parse(output.string)).to include("dry_run" => true)
  end

  private

  def sync_item_class(name, provider)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end)
  end

  def item_for(item_class, external_id, confidence)
    collection = SyncCollection.create!(
      title: "#{item_class.name} collection",
      mapping_method: confidence == "low" ? "manual_backfill" : "source_sync_id",
      mapping_confidence: confidence,
      mapping_established_at: collection_time,
      mapping_last_observed_at: collection_time
    )
    item_class.create!(
      options: options,
      title: "Backfill task",
      external_id:,
      sync_collection: collection
    )
  end
end
