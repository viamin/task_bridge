# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:backfill_baseline_observations task", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_baseline_observations")
  end

  let(:task) { Rake::Task["task_bridge:backfill_baseline_observations"] }
  let(:item_class) do
    stub_const("BackfillBaselineObservationsItem", Class.new(Base::SyncItem) do
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
  let(:now) { Time.zone.parse("2026-10-12T12:00:00.000000Z") }

  before do
    task.reenable
    item_class
    Thread.current[:global_options] = options.merge(pretend: false)
    allow(Time).to receive(:current).and_return(now)
    ENV["DRY_RUN"] = nil
  end

  it "writes baseline item snapshots and mapping rows idempotently" do
    collection = SyncCollection.create!(
      title: "Release checklist",
      mapping_method: "source_sync_id",
      mapping_confidence: "high"
    )
    source_item = item_class.create!(
      title: "Buy milk",
      external_id: "of-task-1",
      last_modified: Time.zone.parse("2026-10-01T00:00:00Z"),
      last_observed_at: Time.zone.parse("2026-10-01T00:00:00Z"),
      sync_collection: collection,
      options: options.merge(service_name: "Omnifocus")
    )

    capture_stdout { task.invoke }
    task.reenable
    first_item_id = OutboxEntry.where(record_kind: "item").first.id
    first_mapping_id = OutboxEntry.where(record_kind: "mapping").first.id

    capture_stdout { task.invoke }
    task.reenable

    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(1)
    expect(OutboxEntry.find(first_item_id)).to be_persisted
    expect(OutboxEntry.find(first_mapping_id)).to be_persisted
    expect(source_item.reload.last_snapshot).to be_present
  end

  it "supports --dry-run via DRY_RUN=1 without writing rows" do
    collection = SyncCollection.create!(
      title: "Release checklist",
      mapping_method: "source_sync_id",
      mapping_confidence: "high"
    )
    item_class.create!(
      title: "Buy milk",
      external_id: "of-task-2",
      last_modified: Time.zone.parse("2026-10-01T00:00:00Z"),
      sync_collection: collection,
      options: options.merge(service_name: "Omnifocus")
    )

    ENV["DRY_RUN"] = "1"
    capture_stdout { task.invoke }
    task.reenable

    expect(OutboxEntry.count).to eq(0)
  end

  it "prints the completion summary after a live run" do
    item_class.create!(
      title: "Buy milk",
      external_id: "of-task-3",
      last_modified: Time.zone.parse("2026-10-01T00:00:00Z"),
      options: options.merge(service_name: "Omnifocus")
    )

    output = capture_stdout { task.invoke }
    task.reenable

    expect(output).to include("Baseline backfill complete")
  end

  def capture_stdout
    original = $stdout
    captured = StringIO.new
    $stdout = captured
    yield
    captured.string
  ensure
    $stdout = original
  end
end
