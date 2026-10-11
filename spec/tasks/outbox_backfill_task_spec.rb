# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:outbox:backfill tasks" do
  include ActiveSupport::Testing::TimeHelpers

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill")
  end

  let(:backfill_task) { Rake::Task["task_bridge:outbox:backfill"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_dry_run"] }
  let(:observed_at) { Time.zone.parse("2026-10-10T10:00:00Z") }

  before do
    backfill_task.reenable
    dry_run_task.reenable
    travel_to(observed_at) do
      Omnifocus::Task.create!(title: "Ship the release", external_id: "of-77", last_modified: observed_at)
    end
  end

  it "seeds baseline rows through the backfill and prints the summary" do
    output = capture_stdout { backfill_task.invoke }

    summary = JSON.parse(output.sub("Outbox backfill: ", ""))
    expect(summary).to include(
      "dry_run" => false,
      "items" => include("enqueued_by_service" => include("omnifocus" => 1))
    )
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
  end

  it "writes nothing in the dry-run task and reports counts by service and confidence" do
    stdout, = capture_output { dry_run_task.invoke }

    expect(stdout).to start_with("Outbox backfill dry run (nothing was written): ")
    summary = JSON.parse(stdout.sub("Outbox backfill dry run (nothing was written): ", ""))
    expect(summary).to include(
      "dry_run" => true,
      "items" => include("enqueued_by_service" => include("omnifocus" => 1), "skipped_by_reason" => {}),
      "mappings" => include("collections" => 0, "enqueued_by_confidence" => {}, "withheld_by_confidence" => {})
    )
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
