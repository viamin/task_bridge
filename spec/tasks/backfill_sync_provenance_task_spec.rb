# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:backfill_sync_provenance task", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_sync_provenance")
  end

  let(:task) { Rake::Task["task_bridge:backfill_sync_provenance"] }
  let(:baseline_task) { Rake::Task["task_bridge:backfill_outbox_baseline"] }
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
    baseline_task.reenable
    allow(SyncBackfill::SourceProvenance).to receive(:run!).and_call_original
    test_item_class
    other_item_class
  end

  it "seeds idempotent baseline snapshots for representative services and withholds low-confidence mappings" do
    collection = SyncCollection.create!(
      title: "Release checklist",
      mapping_method: "title_fallback",
      mapping_confidence: "medium",
      mapping_last_observed_at: Time.zone.parse("2026-10-01T12:00:00Z")
    )
    low_confidence_collection = SyncCollection.create!(
      title: "Uncertain match",
      mapping_method: "manual_backfill",
      mapping_confidence: "low"
    )
    services = {
      "Omnifocus" => %w[omnifocus-1 Omnifocus],
      "Asana:work" => %w[asana-1 Asana],
      "Github:repo" => %w[github-1 Github],
      "GoogleTasks:personal" => %w[google-tasks-1 GoogleTasks]
    }
    services.each_with_index do |(service_name, (external_id, provider)), index|
      item_class = Class.new(Base::SyncItem) do
        define_method(:provider) { provider }

        def self.attribute_map
          {}
        end

        def external_data
          {}
        end
      end
      stub_const("BackfillRepresentativeItem#{index}", item_class)
      item_class.create!(
        options: options.merge(service_name:), title: external_id, external_id:, sync_collection: collection
      )
    end
    test_item_class.create!(
      options: options.merge(service_name: "Omnifocus"), title: "Uncertain", external_id: "omnifocus-2",
      sync_collection: low_confidence_collection
    )

    baseline_task.invoke
    baseline_task.reenable
    baseline_task.invoke

    item_rows = OutboxEntry.where(record_kind: "item")
    expect(item_rows.count).to eq(5)
    expect(item_rows.pluck(:service_type)).to include("omnifocus", "asana", "github", "google_tasks")
    expect(item_rows.find_by(external_id: "omnifocus-1").service_instance).to eq("omnifocus:default")
    expect(item_rows.find_by(external_id: "asana-1").payload["provenance"])
      .to include("detected_by" => "backfill", "baseline" => true, "backfilled_at" => be_present)
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(4)
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:external_id)).not_to include("omnifocus-2")
    expect(OutboxEntry.where(record_kind: "mapping").pluck(:payload).map { |payload| payload["mapping_confidence"] })
      .to all(eq("inferred"))
  end

  it "reports dry-run counts without writing outbox rows" do
    item = test_item_class.create!(options: options.merge(service_name: "Omnifocus"), title: "Missing ID")
    ENV["DRY_RUN"] = "1"

    output = capture_stdout { baseline_task.invoke }
    report = JSON.parse(output)

    expect(report).to include("dry_run" => true, "skipped" => include("missing_external_id" => 1))
    expect(OutboxEntry.count).to eq(0)
    expect(item.reload.last_snapshot).to be_nil
  ensure
    ENV.delete("DRY_RUN")
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

  def capture_stdout
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end
end
