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
  let(:summary) do
    {
      status: "completed",
      items: { considered: 2, enqueued: 2, skipped: 0, dropped: 0, by_service: { "omnifocus" => { enqueued: 2 } } },
      mappings: {
        memberships: 1,
        enqueued: 1,
        withheld: 0,
        skipped: 0,
        dropped: 0,
        by_service: { "asana_work" => { enqueued: 1 } },
        by_confidence: { "high" => 1 }
      },
      skipped_reasons: { "memberships_withheld_low_confidence" => 1 }
    }
  end

  before do
    backfill_task.reenable
    dry_run_task.reenable
    allow(Outbox::Backfill).to receive(:run!).and_return(summary)
  end

  it "runs the backfill and prints the summary counts" do
    output = capture_stdout { backfill_task.invoke }

    expect(Outbox::Backfill).to have_received(:run!)
    expect(output).to include("Outbox baseline backfill completed:")
    expect(output).to include("items: considered=2 enqueued=2 skipped=0 dropped=0")
    expect(output).to include("item omnifocus: enqueued=2")
    expect(output).to include("mappings: memberships=1 enqueued=1 withheld=0 skipped=0 dropped=0")
    expect(output).to include("mapping asana_work: enqueued=1")
    expect(output).to include("mapping confidence: high=1")
    expect(output).to include("skipped reasons: memberships_withheld_low_confidence=1")
  end

  it "previews counts without writing outbox rows in the dry-run task" do
    allow(Outbox::Backfill).to receive(:run!).with(dry_run: true).and_return(summary.merge(status: "dry_run"))

    output = capture_stdout { dry_run_task.invoke }

    expect(Outbox::Backfill).to have_received(:run!).with(dry_run: true)
    expect(output).to include("Outbox baseline backfill dry_run:")
  end

  it "writes baseline rows through the service end to end" do
    allow(Outbox::Backfill).to receive(:run!).and_call_original
    Omnifocus::Task.create!(
      options: { services: [], primary: "Omnifocus", tags: [], service_name: "Omnifocus" },
      title: "Task bridge item",
      external_id: "of-task-1"
    )

    capture_stdout { backfill_task.invoke }

    expect(OutboxEntry.find_by(record_kind: "item", external_id: "of-task-1")).to be_present
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
