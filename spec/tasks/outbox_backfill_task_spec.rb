# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:outbox:backfill_baseline tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:backfill_task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_baseline_dry_run"] }
  let(:item_class) do
    stub_const("OutboxBackfillTaskItem", Class.new(Base::SyncItem) do
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

  before do
    backfill_task.reenable
    dry_run_task.reenable
    item_class
  end

  it "enqueues baseline rows and prints the summary" do
    item_class.create!(title: "Buy milk", external_id: "asana-1", options: { service_name: "Asana:work", services: [], primary: "Omnifocus", tags: [] })

    output = capture_stdout { backfill_task.invoke }

    expect(output).to include("Items: 1 planned, 0 skipped incomplete")
    expect(output).to include("Items by service: asana: 1 planned")
    expect(output).to include("Withheld low-confidence memberships: none")
    expect(OutboxEntry.where(record_kind: "item").map(&:external_id)).to eq(["asana-1"])
    expect(OutboxEntry.where(record_kind: "observation")).to be_empty
  end

  it "previews without writing anything" do
    item_class.create!(title: "Buy milk", external_id: "asana-1", options: { service_name: "Asana:work", services: [], primary: "Omnifocus", tags: [] })

    stdout, stderr = capture_output { dry_run_task.invoke }

    expect(stdout).to include("Items: 1 planned, 0 skipped incomplete")
    expect(stderr).to include("Baseline dry run: nothing was written, nothing was sent")
    expect(OutboxEntry.count).to eq(0)
  end

  private

  def capture_stdout
    original = $stdout
    captured = StringIO.new
    $stdout = captured
    yield
    captured.string
  ensure
    $stdout = original
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
end
