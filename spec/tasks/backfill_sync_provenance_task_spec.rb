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
    expect(OutboxEntry.where(record_kind: "item").count).to eq(2)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(2)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.find_by!(record_kind: "item", external_id: "of-456").payload).to include(
      "provenance" => include("detected_by" => "backfill"),
      "source" => include("service_instance" => "omnifocus:default")
    )
  end

  it "previews counts without writing baseline data" do
    test_item_class.create!(title: "Incomplete", external_id: nil)
    item = test_item_class.create!(title: "Google task", external_id: "google-123")
    item.update_columns(last_observed_at: nil, first_observed_at: nil, last_snapshot: nil)

    previous_dry_run = ENV.fetch("DRY_RUN", nil)
    ENV["DRY_RUN"] = "1"
    begin
      expect { task.invoke }.to output(/Sync backfill dry run:.*items_asana/).to_stdout
    ensure
      ENV["DRY_RUN"] = previous_dry_run
    end

    expect(item.reload.last_observed_at).to be_nil
    expect(OutboxEntry.where(record_kind: "item")).to be_empty
  end

  it "backfills representative provider identities" do
    %w[Omnifocus Asana Github GoogleTasks].each do |provider|
      item_class = Class.new(Base::SyncItem) do
        define_method(:provider) { provider }

        def self.attribute_map
          {}
        end

        def external_data
          {}
        end
      end
      stub_const("#{provider}BackfillItem", item_class)
      item_class.create!(title: provider, external_id: "#{provider.downcase}-1")
    end

    expect { task.invoke }.to output.to_stdout

    expect(OutboxEntry.where(record_kind: "item").pluck(:service_type, :service_instance)).to contain_exactly(
      ["omnifocus", "omnifocus:default"],
      ["asana", "asana:default"],
      ["github", "github:default"],
      ["google_tasks", "google_tasks:default"]
    )
  end
end
