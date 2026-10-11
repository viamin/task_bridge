# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill_baseline tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:backfill_task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_baseline_dry_run"] }

  before do
    backfill_task.reenable
    dry_run_task.reenable
  end

  def create_legacy_item
    item = Omnifocus::Task.create!(
      title: "Buy milk",
      external_id: "of-1",
      options: { service_name: "Omnifocus", services: [], primary: "Omnifocus", tags: [] }
    )
    # Simulate a row persisted before the #217 provenance columns existed.
    item.update_columns(
      source_service_name: nil,
      source_service_instance: nil,
      source_service_type: nil,
      source_external_id: nil,
      source_url: nil,
      first_observed_at: nil,
      last_observed_at: nil
    )
    item
  end

  it "backfills provenance, enqueues baseline rows, and prints the summary" do
    item = create_legacy_item

    expect { backfill_task.invoke }
      .to output(/Items: 1 total, 1 enqueued, 0 already backfilled, 0 skipped/).to_stdout

    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
    expect(item.reload.source_service_name).to eq("Omnifocus")
    expect(item.source_service_instance).to be_nil
    expect(OutboxEntry.where(record_kind: "item").first.service_instance).to eq("omnifocus:default")

    backfill_task.reenable
    expect { backfill_task.invoke }.to output(/1 already backfilled/).to_stdout
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
  end

  it "previews without writing anything in the dry-run task" do
    create_legacy_item

    expect { dry_run_task.invoke }
      .to output(/Baseline backfill dry run \(nothing was enqueued\).*Items: 1 total, 1 to enqueue/m).to_stdout

    expect(OutboxEntry.count).to eq(0)
  end
end
