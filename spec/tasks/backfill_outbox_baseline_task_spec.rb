# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:backfill_outbox_baseline tasks", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_outbox_baseline")
  end

  let(:task) { Rake::Task["task_bridge:backfill_outbox_baseline"] }
  let(:dry_run_task) { Rake::Task["task_bridge:backfill_outbox_baseline_dry_run"] }

  before do
    task.reenable
    dry_run_task.reenable
    Omnifocus::Task.create!(title: "Buy milk", external_id: "of-1", source_service_name: "Omnifocus",
                            options: options.merge(service_name: "Omnifocus"))
    SyncBackfill::SourceProvenance.run!
  end

  def capture_stdout
    original = $stdout
    captured = StringIO.new
    $stdout = captured
    yield
    captured.string
  ensure
    $stdout = original
  end

  it "writes baseline outbox rows and prints a JSON summary" do
    output = capture_stdout { task.invoke }

    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
    expect(JSON.parse(output).dig("items", "enqueued")).to eq(1)
  end

  it "previews the baseline without writing anything" do
    output = capture_stdout { dry_run_task.invoke }

    expect(OutboxEntry.count).to eq(0)
    expect(JSON.parse(output).dig("items", "enqueued")).to eq(1)
  end
end
