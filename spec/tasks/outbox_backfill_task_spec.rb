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

  let(:collection) do
    SyncCollection.create!(title: "Buy milk", mapping_method: "source_sync_id", mapping_confidence: "high")
  end

  before do
    backfill_task.reenable
    dry_run_task.reenable
    Asana::Task.create!(title: "Buy milk", external_id: "asana-1", sync_collection: collection,
                        options: { service_name: "Asana:work", services: [], primary: "Omnifocus", tags: [] })
  end

  it "enqueues baseline rows through the backfill and prints the summary" do
    output = capture_stdout { backfill_task.invoke }

    expect(output).to include("Outbox backfill: 1 item snapshots enqueued (0 already present, 0 skipped), " \
                              "1 mappings enqueued (0 already present, 0 low-confidence memberships withheld, 0 skipped)")
    expect(output).to include("Items by service: asana=1")
    expect(output).to include("Mappings by confidence: confirmed=1")
    expect(OutboxEntry.where(record_kind: "item", external_id: "asana-1")).to be_present
  end

  it "reports idempotent reruns through the task" do
    capture_stdout { backfill_task.invoke }
    backfill_task.reenable
    output = capture_stdout { backfill_task.invoke }

    expect(output).to include("0 item snapshots enqueued (1 already present")
    expect(output).to include("0 mappings enqueued (1 already present")
    expect(OutboxEntry.count).to eq(2)
  end

  it "previews the backfill without writing anything" do
    stdout, stderr = capture_output { dry_run_task.invoke }

    expect(stdout).to include("Outbox backfill dry run (nothing was written): would enqueue 1 item snapshots " \
                              "(0 skipped) and 1 mappings (0 low-confidence memberships would be withheld, 0 skipped)")
    expect(stdout).to include("Items by service: asana=1")
    expect(stdout).to include("Mappings by confidence: confirmed=1")
    expect(stderr).to be_empty
    expect(OutboxEntry.count).to eq(0)
  end

  it "warns when the dry run sees provenance that the apply run would backfill first" do
    collection.update_columns(mapping_method: nil, mapping_confidence: nil)

    _stdout, stderr = capture_output { dry_run_task.invoke }

    expect(stderr).to include("source provenance is not fully backfilled yet")
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

  def capture_output(&)
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
