# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:outbox:backfill tasks", :full_options do
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
    item_class.create!(options:, title: "Buy milk", external_id: "of-1")
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

  it "backfills baseline item snapshots and prints a summary" do
    output = capture_stdout { backfill_task.invoke }

    expect(output).to include("Backfilled 1 item snapshots and 0 mapping rows")
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
  end

  it "runs idempotently when invoked twice" do
    capture_stdout { backfill_task.invoke }
    backfill_task.reenable
    capture_stdout { backfill_task.invoke }

    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
  end

  it "writes nothing in the dry-run task" do
    output = capture_stdout { dry_run_task.invoke }

    expect(JSON.parse(output)["items"]["enqueued"]).to eq(1)
    expect(OutboxEntry.count).to eq(0)
  end
end
