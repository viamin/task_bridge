# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:outbox:backfill_baseline task", :full_options do
  include ActiveSupport::Testing::TimeHelpers

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }
  let(:now) { Time.zone.parse("2026-10-11T12:00:00Z") }

  before do
    task.reenable
    Thread.current[:global_options] = nil
    allow(SyncBackfill::OutboxBaseline).to receive(:run!).and_call_original
  end

  def create_item
    travel_to(now - 1.day) do
      Omnifocus::Task.create!(title: "Buy milk", external_id: "of-task-1",
                              options: { services: [], primary: "Omnifocus", tags: [] })
    end
  end

  it "enqueues baseline rows and prints the rendered summary" do
    create_item

    output = capture_stdout do
      travel_to(now) { task.invoke }
    end

    expect(SyncBackfill::OutboxBaseline).to have_received(:run!).with(dry_run: false)
    expect(OutboxEntry.where(record_kind: "item")).to exist
    expect(output).to include("Outbox baseline backfill")
    expect(output).to include("Items: 1 baseline snapshot rows enqueued")
    expect(output).not_to include("DRY RUN")
  end

  it "writes nothing and prints the dry-run summary when DRY_RUN is set" do
    create_item

    output = with_dry_run_env do
      capture_stdout do
        travel_to(now) { task.invoke }
      end
    end

    expect(SyncBackfill::OutboxBaseline).to have_received(:run!).with(dry_run: true)
    expect(OutboxEntry.count).to eq(0)
    expect(output).to include("DRY RUN — nothing was written")
    expect(output).to include("Items: 1 baseline snapshot rows would be enqueued")
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

  def with_dry_run_env
    ENV["DRY_RUN"] = "1"
    yield
  ensure
    ENV.delete("DRY_RUN")
  end
end
