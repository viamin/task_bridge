# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:outbox:backfill tasks" do
  include ActiveSupport::Testing::TimeHelpers

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill")
  end

  let(:backfill_task) { Rake::Task["task_bridge:outbox:backfill"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_dry_run"] }
  let(:options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }
  let(:collection) do
    SyncCollection.create!(title: "Manual guess", mapping_method: "manual_backfill", mapping_confidence: "low")
  end

  before do
    backfill_task.reenable
    dry_run_task.reenable
    Omnifocus::Task.create!(options:, title: "Buy milk", external_id: "of-1", sync_collection: collection)
    Asana::Task.create!(options: options.merge(service_name: "Asana:work"), title: "Buy milk", external_id: "asana-1")
  end

  it "seeds the baseline rows and prints the summary" do
    output = capture_stdout { travel_to(Time.zone.parse("2026-10-11T09:00:00Z")) { backfill_task.invoke } }

    expect(output).to start_with("Outbox backfill:")
    expect(output).not_to include("dry run")
    expect(output).to include("2 item snapshots enqueued")
    expect(output).to include("1 memberships withheld (low/unknown confidence)")
    expect(output).to include("SyncCollection ##{collection.id} \"Manual guess\" member omnifocus:of-1")
    expect(OutboxEntry.where(record_kind: "item").map(&:external_id)).to eq(%w[of-1 asana-1])
    expect(OutboxEntry.where(record_kind: "mapping")).to be_empty
  end

  it "previews without writing anything in the dry-run task" do
    output = capture_stdout { dry_run_task.invoke }

    expect(output).to include("(dry run: nothing was written)")
    expect(output).to include("2 item snapshots enqueued")
    expect(output).to include("low: 0 enqueued, 1 withheld, 0 skipped")
    expect(OutboxEntry.count).to eq(0)
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
