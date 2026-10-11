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
    expect(source_item.source_created_at).to be_nil
    expect(target_item.reload.source_service_name).to eq("Omnifocus")
    expect(target_item.source_service_instance).to eq("default")
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
    expect(OutboxEntry.where(record_kind: "item").count).to eq(2)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(2)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.find_by!(record_kind: "item", external_id: "asana-123").payload).to include(
      "contract_version" => 1,
      "provenance" => include("detected_by" => "backfill", "baseline" => true)
    )
    expect(source_item.reload.last_snapshot).to include("title" => "Buy milk")
  end

  it "previews representative source snapshots without writing or publishing low-confidence mappings" do
    github_item_class = stub_const("BackfillGithubItem", Class.new(Base::SyncItem) do
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
    google_tasks_item_class = stub_const("BackfillGoogleTasksItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "GoogleTasks"
      end

      def external_data
        {}
      end
    end)
    low_confidence_collection = SyncCollection.create!(
      title: "Needs review", mapping_method: "title_fallback", mapping_confidence: "low"
    )
    [
      [test_item_class, "Asana:work", "asana-1"],
      [other_item_class, "Omnifocus", "omnifocus-1"],
      [github_item_class, "Github:repo", "github-1"],
      [google_tasks_item_class, "GoogleTasks", "google-tasks-1"]
    ].each do |item_class, service_name, external_id|
      item_class.create!(
        options: options.merge(service_name:), title: external_id, external_id:, sync_collection: low_confidence_collection
      )
    end

    summary = SyncBackfill::SourceProvenance.run!(dry_run: true)

    expect(summary[:items]).to include("asana" => 1, "omnifocus" => 1, "github" => 1, "google_tasks" => 1)
    expect(summary[:mappings]).to include("low" => 4)
    expect(summary[:skipped]).to include("low_confidence_mapping" => 1)
    expect(OutboxEntry.all).to be_empty
    expect(low_confidence_collection.reload.mapping_method).to eq("title_fallback")

    SyncBackfill::SourceProvenance.run!

    expect(OutboxEntry.where(record_kind: "item").pluck(:service_type)).to contain_exactly(
      "asana", "omnifocus", "github", "google_tasks"
    )
    expect(OutboxEntry.where(record_kind: "mapping")).to be_empty
  end
end
