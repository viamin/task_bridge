# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill_baseline task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }

  before do
    task.reenable
    allow(Outbox::BaselineBackfill).to receive(:run!).and_call_original
  end

  it "runs the backfill and prints the summary" do
    expect { task.invoke }
      .to output(/Backfill baseline: 0 of 0 items enqueued/).to_stderr
      .and output(/"dry_run": false/).to_stdout

    expect(Outbox::BaselineBackfill).to have_received(:run!).with(dry_run: false)
  end

  it "previews without writing when DRY_RUN is set" do
    ENV["DRY_RUN"] = "1"

    expect { task.invoke }
      .to output(/Backfill baseline dry run: 0 of 0 items enqueued/).to_stderr
      .and output(/"dry_run": true/).to_stdout

    expect(Outbox::BaselineBackfill).to have_received(:run!).with(dry_run: true)
  ensure
    ENV.delete("DRY_RUN")
  end
end
