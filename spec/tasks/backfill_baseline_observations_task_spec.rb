# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:backfill_baseline_observations tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_baseline_observations")
  end

  let(:task) { Rake::Task["task_bridge:backfill_baseline_observations"] }
  let(:dry_run_task) { Rake::Task["task_bridge:backfill_baseline_observations_dry_run"] }
  let(:test_item_class) do
    stub_const("BackfillBaselineTaskItem", Class.new(Base::SyncItem) do
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
    dry_run_task.reenable
    test_item_class
  end

  def create_item(external_id:)
    test_item_class.create!(
      options: { service_name: "Omnifocus", services: [], primary: "Omnifocus", tags: [] },
      title: "Buy milk",
      external_id:
    )
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

  it "writes baseline item outbox rows and prints a summary" do
    create_item(external_id: "of-1")

    output = capture_stdout { task.invoke }

    expect(output).to include("Item snapshots: 1 enqueued, 0 skipped (incomplete identity)")
    expect(output).to include('"omnifocus" => 1')
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
  end

  it "writes nothing in the dry-run task but still reports counts" do
    create_item(external_id: "of-2")

    output = capture_stdout { dry_run_task.invoke }

    expect(output).to include("[dry run] Item snapshots: 1 enqueued")
    expect(OutboxEntry.where(record_kind: "item")).to be_empty
  end

  it "is safe to run repeatedly" do
    create_item(external_id: "of-3")

    capture_stdout { task.invoke }
    task.reenable
    capture_stdout { task.invoke }

    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
  end
end
