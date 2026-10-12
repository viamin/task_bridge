# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:backfill_sync_provenance task", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_sync_provenance")
  end

  let(:task) { Rake::Task["task_bridge:backfill_sync_provenance"] }
  let(:test_item_class) do
    stub_const("BackfillSyncTaskItem", Class.new(Base::SyncItem) do
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
  let(:other_item_class) do
    stub_const("BackfillSyncTaskOtherItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Omnifocus"
      end

      def external_data
        {}
      end
    end)
  end

  before do
    task.reenable
    allow(SyncBackfill::SourceProvenance).to receive(:run!).and_call_original
    test_item_class
    other_item_class
  end

  it "backfills explicit source and mapping provenance idempotently" do
    collection = SyncCollection.create!(title: "Buy milk")
    source_item = test_item_class.create!(
      options: options.merge(service_name: "Asana:work"),
      title: "Buy milk",
      external_id: "asana-123",
      notes: "omnifocus_id: of-456",
      sync_collection: collection
    )
    target_item = other_item_class.create!(
      options: options.merge(service_name: "Omnifocus"),
      title: "Buy milk",
      external_id: "of-456",
      notes: "asana_work_id: asana-123",
      sync_collection: collection
    )

    source_item.update_columns(
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
    target_item.update_columns(
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
    collection.update_columns(
      mapping_method: nil,
      mapping_confidence: nil,
      mapping_metadata: nil,
      mapping_established_at: nil,
      mapping_last_observed_at: nil
    )

    task.invoke
    task.reenable
    first_run = {
      source_observed_at: source_item.reload.last_observed_at,
      target_observed_at: target_item.reload.last_observed_at,
      collection_observed_at: collection.reload.mapping_last_observed_at,
      collection_updated_at: collection.updated_at
    }

    task.invoke
    task.reenable

    expect(SyncBackfill::SourceProvenance).to have_received(:run!).twice
    expect(source_item.reload.source_service_name).to eq("Asana:work")
    expect(source_item.source_service_instance).to eq("work")
    expect(source_item.source_external_id).to eq("asana-123")
    expect(source_item.source_created_at).to be_nil
    expect(target_item.reload.source_service_name).to eq("Omnifocus")
    expect(target_item.source_created_at).to be_nil
    expect(collection.reload.mapping_method).to eq("source_sync_id")
    expect(collection.mapping_confidence).to eq("high")
    expect(collection.mapping_metadata).to include("note_key" => "omnifocus_id")
    expect(collection.mapping_established_at).to be_present
    expect(collection.mapping_last_observed_at).to be_present
    expect(source_item.reload.last_observed_at).to eq(first_run[:source_observed_at])
    expect(target_item.reload.last_observed_at).to eq(first_run[:target_observed_at])
    expect(collection.reload.mapping_last_observed_at).to eq(first_run[:collection_observed_at])
    expect(collection.updated_at).to eq(first_run[:collection_updated_at])
  end

  it "seeds representative service snapshots without historical observations" do
    collection = SyncCollection.create!(title: "Release checklist")
    items = [
      backfill_item_class("BackfillOmniFocusItem", "OmniFocus"),
      backfill_item_class("BackfillAsanaItem", "Asana"),
      backfill_item_class("BackfillGithubItem", "Github"),
      backfill_item_class("BackfillGoogleTasksItem", "GoogleTasks")
    ].map.with_index do |item_class, index|
      item_class.create!(
        options: options.merge(service_name: item_class.new.provider),
        title: "Release checklist",
        external_id: "item-#{index}",
        sync_collection: collection
      )
    end

    SyncBackfill::SourceProvenance.run!(output: StringIO.new)

    rows = OutboxEntry.where(record_kind: "item").order(:external_id)
    expect(rows.pluck(:service_type)).to contain_exactly("omni_focus", "asana", "github", "google_tasks")
    expect(rows.pluck(:service_instance)).to contain_exactly(
      "omni_focus:default", "asana:default", "github:default", "google_tasks:default"
    )
    expect(rows.map { |row| row.payload.dig("provenance", "detected_by") }).to all(eq("backfill"))
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(items.map { |item| item.reload.last_snapshot }).to all(be_present)

    expect do
      SyncBackfill::SourceProvenance.run!(output: StringIO.new)
    end.not_to change(OutboxEntry, :count)
  end

  it "previews counts without changing provenance, snapshots, or mappings" do
    collection = SyncCollection.create!(title: "Buy milk")
    item = test_item_class.create!(
      options: options.merge(service_name: "Asana"),
      title: "Buy milk",
      external_id: "asana-123",
      sync_collection: collection
    )
    item.update_columns(first_observed_at: nil, last_observed_at: nil, source_service_name: nil,
                        source_service_instance: nil, source_service_type: nil, source_external_id: nil,
                        source_url: nil, source_updated_at: nil, source_metadata: nil)
    output = StringIO.new

    SyncBackfill::SourceProvenance.run!(dry_run: true, output:)

    expect(item.reload.first_observed_at).to be_nil
    expect(item.last_snapshot).to be_nil
    expect(collection.reload.mapping_method).to be_nil
    expect(OutboxEntry.count).to eq(0)
    expect(output.string).to include("TaskBridge sync backfill dry run:", "service.asana.preview: 1")
    expect(output.string).to include("mappings.low.withheld: 1")
  end

  def backfill_item_class(name, provider_name)
    stub_const(name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider_name }

      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end)
  end
end
