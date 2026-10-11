# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill")
  end

  let(:backfill_task) { Rake::Task["task_bridge:outbox:backfill"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_dry_run"] }
  let!(:item) { Omnifocus::Task.create!(title: "Buy milk", external_id: "of-1") }

  before do
    backfill_task.reenable
    dry_run_task.reenable
  end

  it "backfill enqueues baseline rows and prints the summary" do
    expect { backfill_task.invoke }
      .to output(/Outbox backfill\n\s+item snapshots:\n\s+enqueued by service: omnifocus=1/).to_stdout

    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
  end

  it "backfill_dry_run prints the summary without writing outbox rows" do
    expect { dry_run_task.invoke }.to output(/Outbox backfill dry run \(no outbox rows are written\)/).to_stdout

    expect(OutboxEntry.count).to eq(0)
  end
end
