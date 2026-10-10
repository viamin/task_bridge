# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill_baseline tasks", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_baseline_dry_run"] }
  let(:baseline_rows) { OutboxEntry.where(record_kind: "item") }
  let(:mapping_rows) { OutboxEntry.where(record_kind: "mapping") }

  def create_item(item_class, attributes)
    item_class.create!({ options: }.merge(attributes))
  end

  before do
    task.reenable
    dry_run_task.reenable
    Thread.current[:global_options] = nil
  end

  it "enqueues baseline rows and prints a summary with service and confidence counts" do
    collection = SyncCollection.create!(
      title: "Buy milk",
      mapping_method: "source_sync_id",
      mapping_confidence: "high",
      mapping_last_observed_at: Time.zone.parse("2026-10-09T09:00:00Z")
    )
    create_item(Omnifocus::Task, title: "Buy milk", external_id: "of-1",
                                 sync_collection: collection)
    create_item(Asana::Task, title: "Buy milk", external_id: "asana-1",
                             sync_collection: collection,
                             options: options.merge(service_name: "Asana:work"))

    expect { task.invoke }
      .to output(/Items: 2 enqueued, 0 already present, 0 skipped \(no external id\), 0 errors/)
      .to_stdout
    task.reenable
    expect { task.invoke }
      .to output(/Items: 0 enqueued, 2 already present/).to_stdout

    expect(baseline_rows.count).to eq(2)
    expect(mapping_rows.count).to eq(2)
    expect(OutboxEntry.where(record_kind: %w[observation sync_run])).to be_empty
  end

  it "lists withheld low-confidence memberships and skipped records in the dry run" do
    low_collection = SyncCollection.create!(
      title: "Unclear",
      mapping_method: "manual_backfill",
      mapping_confidence: "low",
      mapping_last_observed_at: Time.zone.parse("2026-10-09T09:00:00Z")
    )
    create_item(Omnifocus::Task, title: "One thing", external_id: "of-2",
                                 sync_collection: low_collection)
    create_item(Reclaim::Task, title: "Another thing", external_id: "rc-2",
                               sync_collection: low_collection)
    create_item(Github::Issue, title: "No identity", external_id: nil)

    expect { dry_run_task.invoke }.to output(
      /Baseline outbox backfill \(dry run: nothing was written\).*Items: 2 enqueued, 0 already present, 1 skipped \(no external id\), 0 errors.*Mappings: 0 enqueued, 0 already present, 2 withheld \(low confidence\), 0 skipped members, 0 errors.*withheld by confidence: low=2/m
    ).to_stdout

    expect(OutboxEntry.count).to eq(0)
    expect(low_collection.reload.mapping_confidence).to eq("low")
  end
end
