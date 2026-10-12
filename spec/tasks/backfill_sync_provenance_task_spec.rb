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
end

RSpec.describe "task_bridge:backfill_outbox task", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_outbox")
  end

  let(:task) { Rake::Task["task_bridge:backfill_outbox"] }

  def create_item(provider:, external_id:, collection: nil, notes: nil, title: nil)
    constant_name = "BackfillOutbox#{provider.gsub(/[^a-z0-9]/i, '')}Item"
    item_class = constant_name.safe_constantize || stub_const(constant_name, Class.new(Base::SyncItem) do
      define_method(:provider) { provider }

      def self.attribute_map
        {}
      end

      def external_data
        {}
      end
    end)
    item_class.create!(
      title: title || "Existing #{provider} item", external_id:, notes:, sync_collection: collection,
      options: options.merge(service_name: provider)
    )
  end

  before { task.reenable }

  it "seeds idempotent baseline snapshots for representative services without observations" do
    high = SyncCollection.create!(title: "Confirmed", mapping_method: "source_sync_id", mapping_confidence: "high")
    medium = SyncCollection.create!(title: "Inferred", mapping_method: "title_fallback", mapping_confidence: "medium")
    low = SyncCollection.create!(title: "Tentative", mapping_method: "manual_backfill", mapping_confidence: "low")
    %w[Omnifocus Asana Github GoogleTasks].each_with_index do |provider, index|
      create_item(provider:, external_id: "#{provider.downcase}-#{index}", collection: [high, medium, low, high][index])
    end

    expect { task.invoke }.to output(/"services"/).to_stdout
    expect(OutboxEntry.where(record_kind: "item").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(3)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).not_to include("github-2")
    expect(OutboxEntry.where(record_kind: "item").pluck(:service_instance))
      .to include("omnifocus:default", "asana:default", "github:default", "google_tasks:default")
    expect(OutboxEntry.where(record_kind: "item").first.payload).to include(
      "provenance" => include("detected_by" => "backfill", "backfilled_at" => be_present)
    )
    expect(Base::SyncItem.where.not(external_id: nil).pluck(:last_snapshot)).to all(be_present)

    task.reenable
    expect { task.invoke }.not_to change(OutboxEntry, :count)
  end

  it "reports records without external identities and does not write in dry-run mode" do
    create_item(provider: "Asana", external_id: "asana-1")
    create_item(provider: "Github", external_id: nil)
    ENV["DRY_RUN"] = "1"

    expect { task.invoke }.to output(/"incomplete_items":1/).to_stdout
    expect(OutboxEntry.all).to be_empty
  ensure
    ENV.delete("DRY_RUN")
  end

  it "predicts unbackfilled title mappings without mutating local provenance" do
    collection = SyncCollection.create!(title: "Shared title")
    create_item(provider: "Asana", external_id: "asana-1", collection:, title: "Shared title")
    create_item(provider: "Omnifocus", external_id: "omnifocus-1", collection:, title: "Shared title")
    ENV["DRY_RUN"] = "1"

    expect { task.invoke }.to output(/"mapping_methods":\{"title_fallback":2\}/).to_stdout
    expect(collection.reload.mapping_method).to be_nil
    expect(OutboxEntry.all).to be_empty
  ensure
    ENV.delete("DRY_RUN")
  end
end
