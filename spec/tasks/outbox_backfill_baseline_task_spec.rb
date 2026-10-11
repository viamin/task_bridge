# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:outbox:backfill_baseline tasks", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:backfill_task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_baseline_dry_run"] }
  let(:item_class) do
    stub_const("BaselineBackfillTaskItem", Class.new(Base::SyncItem) do
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
    backfill_task.reenable
    dry_run_task.reenable
    item_class
  end

  def capture_output
    original_stdout = $stdout
    original_stderr = $stderr
    captured_stdout = StringIO.new
    captured_stderr = StringIO.new
    $stdout = captured_stdout
    $stderr = captured_stderr
    yield
    [captured_stdout.string, captured_stderr.string]
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end

  it "seeds baseline rows and prints the summary" do
    item = item_class.create!(title: "Buy milk", external_id: "of-1", options: options.merge(service_name: "Omnifocus"))

    output = capture_stdout { backfill_task.invoke }

    expect(output).to include("Baseline backfill (dry run: false)")
    expect(output).to include("Items: 1 candidates — 1 enqueued, 0 already present, 0 skipped (incomplete)")
    expect(output).to include("omnifocus: 1 enqueued")
    expect(OutboxEntry.where(record_kind: "item", external_id: "of-1").count).to eq(1)
    expect(item.reload.last_observed_at).to eq(item.first_observed_at)
  end

  it "prints the withholding counts for low-confidence mappings" do
    collection = SyncCollection.create!(title: "Loosely grouped", mapping_method: "manual_backfill",
                                        mapping_confidence: "low", sync_items: [item_class.create!(title: "Buy milk", external_id: "of-2", options: options.merge(service_name: "Omnifocus"))])

    output = capture_stdout { backfill_task.invoke }

    expect(output).to include("1 withheld (low/unknown confidence)")
    expect(output).to include("low: 0 enqueued, 0 already present, 1 withheld")
    expect(OutboxEntry.where(record_kind: "mapping", sync_collection_id: collection.id)).to be_empty
  end

  it "summarizes a dry run without writing anything" do
    item_class.create!(title: "Buy milk", external_id: "of-3", options: options.merge(service_name: "Omnifocus"))

    stdout, stderr = capture_output { dry_run_task.invoke }

    expect(stdout).to include("Baseline backfill (dry run: true)")
    expect(stdout).to include("Items: 1 candidates — 1 enqueued")
    expect(stderr).to include("Baseline backfill dry run: nothing was written")
    expect(OutboxEntry.count).to eq(0)
  end

  private

  def capture_stdout(&)
    capture_output(&).first
  end
end
