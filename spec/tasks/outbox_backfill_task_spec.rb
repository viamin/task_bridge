# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill task", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill")
  end

  let(:task) { Rake::Task["task_bridge:outbox:backfill"] }
  let(:summary) do
    {
      dry_run: false,
      items: { enqueued: 1, by_service: { "asana" => 1 }, skipped: {} },
      mappings: { enqueued: 0, by_confidence: {}, skipped: {} }
    }
  end

  before do
    task.reenable
    allow(SyncBackfill::OutboxBaseline).to receive(:run!).and_return(summary)
  end

  it "prints the backfill summary" do
    expect { task.invoke }.to output("#{JSON.generate(summary)}\n").to_stdout

    expect(SyncBackfill::OutboxBaseline).to have_received(:run!).with(dry_run: false)
  end
end
