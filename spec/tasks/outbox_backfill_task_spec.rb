# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill")
  end

  let(:backfill_task) { Rake::Task["task_bridge:outbox:backfill"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_dry_run"] }

  before do
    backfill_task.reenable
    dry_run_task.reenable
  end

  it "runs the backfill" do
    allow(Outbox::Backfill).to receive(:run!)

    backfill_task.invoke

    expect(Outbox::Backfill).to have_received(:run!).with(no_args)
  end

  it "runs the backfill in dry-run mode" do
    allow(Outbox::Backfill).to receive(:run!)

    dry_run_task.invoke

    expect(Outbox::Backfill).to have_received(:run!).with(dry_run: true)
  end
end
