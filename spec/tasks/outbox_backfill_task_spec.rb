# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:outbox:backfill_baseline tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:write_task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }
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
    write_task.reenable
    dry_run_task.reenable
    allow(SyncBackfill::BaselineOutbox).to receive(:run!).and_call_original
    item_class
  end

  def create_item(external_id)
    item_class.create!(title: "Buy milk", external_id:)
  end

  it "enqueues baseline rows and prints the summary" do
    create_item("asana-9")

    output = capture_stdout { write_task.invoke }

    expect(output).to include("Baseline backfill complete: enqueued 1 item snapshot row(s)")
    expect(output).to include("Created 1 new item row(s) and 0 new mapping row(s) this run")
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
    expect(SyncBackfill::BaselineOutbox).to have_received(:run!)
  end

  it "writes nothing in the dry-run task and prints the summary" do
    create_item("asana-9")

    output = capture_stdout { dry_run_task.invoke }

    expect(output).to include("Baseline backfill dry run: would enqueue 1 item snapshot row(s)")
    expect(output).to include("Nothing was written")
    expect(OutboxEntry.count).to eq(0)
    expect(SyncBackfill::BaselineOutbox).to have_received(:run!).with(dry_run: true)
  end

  private

  def capture_stdout(&)
    original = $stdout
    captured = StringIO.new
    $stdout = captured
    yield
    captured.string
  ensure
    $stdout = original
  end
end
