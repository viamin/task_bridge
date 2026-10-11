# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill")
  end

  let(:task) { Rake::Task["task_bridge:outbox:backfill"] }

  before do
    task.reenable
    ENV.delete("DRY_RUN")
  end

  after { ENV.delete("DRY_RUN") }

  it "prints a non-mutating dry-run summary" do
    ENV["DRY_RUN"] = "1"
    allow(Outbox::Backfill).to receive(:run!).with(dry_run: true).and_return(
      items_by_service: { "asana" => 1 }, mappings_by_confidence: {}, skipped_or_incomplete: {}
    )

    expect { task.invoke }
      .to output(/Dry run: would backfill items by service: \{"asana" => 1\}/).to_stdout
  end
end
