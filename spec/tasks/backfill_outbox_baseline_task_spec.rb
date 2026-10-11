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
  let(:base_options) { { services: [], primary: "Omnifocus", tags: [] } }
  let!(:omnifocus_item) do
    Omnifocus::Task.create!(options: base_options, title: "Buy milk", external_id: "of-77")
  end

  before do
    backfill_task.reenable
    dry_run_task.reenable
    allow(SyncBackfill::SourceProvenance).to receive(:run!)
    allow(SyncBackfill::OutboxBaseline).to receive(:run!).and_call_original
  end

  it "runs the provenance backfill first and enqueues the baseline" do
    output = capture_stdout { backfill_task.invoke }

    expect(SyncBackfill::SourceProvenance).to have_received(:run!)
    expect(SyncBackfill::OutboxBaseline).to have_received(:run!)
    expect(output).to include("item snapshots by service: omnifocus=1")
    expect(OutboxEntry.where(record_kind: "item").map(&:external_id)).to eq(["of-77"])
  end

  it "writes nothing in the dry-run task but still reports counts" do
    output = capture_stdout { dry_run_task.invoke }

    expect(SyncBackfill::SourceProvenance).not_to have_received(:run!)
    expect(SyncBackfill::OutboxBaseline).to have_received(:run!).with(dry_run: true)
    expect(output).to include("dry run — nothing was written")
    expect(output).to include("item snapshots by service: omnifocus=1")
    expect(OutboxEntry.count).to eq(0)
    expect(omnifocus_item.reload.last_snapshot).to be_nil
  end

  it "leaves the enqueued rows pending for the publish task instead of publishing" do
    capture_stdout { backfill_task.invoke }

    expect(OutboxEntry.where(record_kind: "item")).to all(be_pending)
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
