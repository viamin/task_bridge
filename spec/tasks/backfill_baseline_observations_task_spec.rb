# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:backfill_baseline_observations tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_baseline_observations:dry_run")
  end

  let(:dry_run_task) { Rake::Task["task_bridge:backfill_baseline_observations:dry_run"] }
  let(:run_task) { Rake::Task["task_bridge:backfill_baseline_observations:run"] }
  let!(:item) do
    Omnifocus::Task.create!(title: "Buy milk", external_id: "of-1",
                            options: { service_name: "Omnifocus", services: [], primary: "Omnifocus", tags: [] })
  end

  before do
    dry_run_task.reenable
    run_task.reenable
  end

  it "dry_run reports a summary without enqueueing anything" do
    expect { dry_run_task.invoke }.to output(/Baseline item snapshots: 1 by service/).to_stdout
    expect(OutboxEntry.count).to eq(0)
  end

  it "run enqueues baseline rows and is idempotent across repeated invocations" do
    expect { run_task.invoke }.to output(/Baseline item snapshots: 1 by service/).to_stdout
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)

    run_task.reenable
    expect { run_task.invoke }.not_to(change { OutboxEntry.where(record_kind: "item").count })
  end
end
