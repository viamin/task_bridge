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
    stub_const("BackfillOutboxTaskItem", Class.new(Base::SyncItem) do
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
  end

  before do
    backfill_task.reenable
    dry_run_task.reenable
    item_class
  end

  it "seeds baseline rows and prints the applied summary" do
    item_class.create!(options: { quiet: true, services: [], primary: "Omnifocus", tags: [] },
                       title: "Fix login", external_id: "gt-9")
    allow(SyncBackfill::BaselineOutbox).to receive(:run!).with(no_args).and_call_original

    output = capture_stdout { backfill_task.invoke }

    expect(output).to include("TaskBridge outbox backfill (applied)")
    expect(output).to include("google_tasks: 1 total, 1 enqueued")
    expect(OutboxEntry.where(record_kind: "item").map(&:external_id)).to eq(["gt-9"])
  end

  it "summarizes without writing anything in the dry run" do
    item_class.create!(options: { quiet: true, services: [], primary: "Omnifocus", tags: [] },
                       title: "Fix login", external_id: "gt-9")
    allow(SyncBackfill::BaselineOutbox).to receive(:run!).with(dry_run: true).and_call_original

    output = capture_stdout { dry_run_task.invoke }

    expect(output).to include("dry run — nothing was written")
    expect(output).to include("google_tasks: 1 total, 1 would enqueue")
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
