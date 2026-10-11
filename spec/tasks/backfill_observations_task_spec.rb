# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:backfill_observations task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_observations")
  end

  let(:task) { Rake::Task["task_bridge:backfill_observations"] }

  around do |example|
    original_dry_run = ENV.fetch("DRY_RUN", nil)
    example.run
  ensure
    ENV["DRY_RUN"] = original_dry_run
  end

  it "prints a dry-run summary without invoking writes" do
    ENV["DRY_RUN"] = "true"
    allow(SyncBackfill::Observations).to receive(:run!).with(dry_run: true).and_return(
      { items: { "asana" => 2 }, mappings: { "low" => 1 }, skipped: { mappings_low_confidence: 1 } }
    )

    expect { task.invoke }.to output(/Dry run: .*"asana":2.*"low":1/).to_stdout
  end
end
