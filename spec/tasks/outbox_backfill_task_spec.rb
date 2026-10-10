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

  let(:options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }
  let!(:omnifocus_task) do
    Omnifocus::Task.create!(title: "Buy milk", external_id: "of-77", options: options.merge(service_name: "Omnifocus"))
  end
  let!(:low_confidence_collection) do
    SyncCollection.create!(title: "Assumed pair", mapping_method: "manual_backfill", mapping_confidence: "low")
  end

  before do
    backfill_task.reenable
    dry_run_task.reenable
  end

  it "enqueues baseline rows and prints the summary with withheld mappings" do
    omnifocus_task.update!(sync_collection: low_confidence_collection)

    output = capture_stdout { backfill_task.invoke }

    expect(output).to include("Outbox backfill complete:")
    expect(output).to include("item snapshots: 1 enqueued, 0 skipped/incomplete")
    expect(output).to include("omnifocus: 1 enqueued, 0 skipped/incomplete")
    expect(output).to include("mapping memberships: 0 enqueued, 1 withheld")
    expect(output).to include("low: 0 enqueued, 1 withheld")
    expect(OutboxEntry.where(record_kind: "item").map(&:external_id)).to eq(["of-77"])
    expect(OutboxEntry.where(record_kind: "mapping")).to be_empty
  end

  it "prints the dry-run summary without writing outbox rows" do
    omnifocus_task.update!(sync_collection: low_confidence_collection)

    output = capture_stdout { dry_run_task.invoke }

    expect(output).to include("Outbox backfill dry run (nothing was written):")
    expect(output).to include("item snapshots: 1 enqueued, 0 skipped/incomplete")
    expect(output).to include("low: 0 enqueued, 1 withheld")
    expect(OutboxEntry.count).to eq(0)
  end

  it "is idempotent when invoked repeatedly" do
    travel_to(Time.zone.parse("2026-10-10T12:00:00Z")) { backfill_task.invoke }
    keys = OutboxEntry.pluck(:idempotency_key)

    backfill_task.reenable
    travel_to(Time.zone.parse("2026-10-11T12:00:00Z")) { backfill_task.invoke }

    expect(OutboxEntry.pluck(:idempotency_key)).to eq(keys)
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
