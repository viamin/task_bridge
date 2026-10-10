# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:outbox:backfill tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill")
  end

  let(:backfill_task) { Rake::Task["task_bridge:outbox:backfill"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_dry_run"] }
  let(:item_class) do
    stub_const("OutboxBackfillTaskItem", Class.new(Base::SyncItem) do
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
    item_class.create!(
      title: "Buy milk",
      external_id: "of-1",
      options: { service_name: "Omnifocus", services: [], primary: "Omnifocus", tags: [] }
    )
  end

  it "enqueues baseline rows through the backfill and prints the summary" do
    output = capture_stdout { backfill_task.invoke }

    expect(output).to include("Outbox backfill complete:")
    expect(output).to include("items: 1 enqueued (0 already present)")
    expect(output).to include("by service: omnifocus=1")
    expect(output).to include("by confidence: ")
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
  end

  it "summarizes without writing rows in the dry-run task" do
    output = capture_stdout { dry_run_task.invoke }

    expect(output).to include("Outbox backfill dry run (nothing was enqueued):")
    expect(output).to include("items: 1 enqueued (0 already present), 0 skipped incomplete")
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
end
