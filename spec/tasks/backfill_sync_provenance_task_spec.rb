# frozen_string_literal: true

require "rails_helper"
require "rake"

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
    expect(source_item.source_created_at).to eq(source_item.created_at)
    expect(target_item.reload.source_service_name).to eq("Omnifocus")
    expect(target_item.source_created_at).to eq(target_item.created_at)
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
end
