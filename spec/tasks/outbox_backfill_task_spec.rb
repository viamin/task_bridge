# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill_baseline tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_baseline_dry_run"] }

  before do
    task.reenable
    dry_run_task.reenable
  end

  let(:asana_item) do
    Asana::Task.create!(
      title: "Buy milk", external_id: "asana-1", source_service_name: "Asana:work",
      last_modified: Time.zone.parse("2026-10-10T08:00:00Z")
    )
  end

  it "enqueues baseline rows and prints the summary" do
    asana_item

    expect { task.invoke }
      .to output(/TaskBridge outbox baseline backfill.*By service: asana=1/m).to_stdout

    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
  end

  it "is safe to invoke repeatedly" do
    asana_item
    task.invoke
    task.reenable

    expect { task.invoke }.to output(/0 enqueued/).to_stdout
    expect(OutboxEntry.count).to eq(1)
  end

  it "previews without writing any rows" do
    asana_item

    expect { dry_run_task.invoke }
      .to output(/\(dry run — nothing written\)/).to_stdout

    expect(OutboxEntry.count).to eq(0)
  end
end
