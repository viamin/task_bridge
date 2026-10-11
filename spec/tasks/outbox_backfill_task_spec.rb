# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill")
  end

  let(:task) { Rake::Task["task_bridge:outbox:backfill"] }

  around do |example|
    original_dry_run = ENV.fetch("DRY_RUN", nil)
    ENV["DRY_RUN"] = "true"
    example.run
  ensure
    ENV["DRY_RUN"] = original_dry_run
  end

  before { task.reenable }

  it "prints the dry-run summary without requesting publication" do
    summary = { dry_run: true, items: { "asana" => 1 }, mappings: {}, skipped: { "mappings_low" => 1 } }
    allow(SyncBackfill::Outbox).to receive(:run!).with(dry_run: true).and_return(summary)

    expect { task.invoke }.to output("#{JSON.generate(summary)}\n").to_stdout
  end
end
