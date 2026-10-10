# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:outbox:backfill task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill")
  end

  let(:task) { Rake::Task["task_bridge:outbox:backfill"] }

  before do
    task.reenable
    allow(SyncBackfill::Baseline).to receive(:run!).and_return(items: 4, mappings: 2)
  end

  it "seeds baseline outbox rows through the backfill service and reports counts" do
    output = capture_stdout { task.invoke }

    expect(SyncBackfill::Baseline).to have_received(:run!)
    expect(output).to include("Backfilled 4 item snapshot rows and 2 confirmed mapping rows into the outbox")
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
