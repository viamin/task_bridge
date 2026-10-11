# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill_baseline tasks", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:backfill_task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_baseline_dry_run"] }

  before do
    backfill_task.reenable
    dry_run_task.reenable
  end

  def create_legacy_pair
    collection = SyncCollection.create!(title: "Buy milk")
    omnifocus_item = Omnifocus::Task.create!(
      options: options.merge(service_name: "Omnifocus"),
      title: "Buy milk", external_id: "of-1", notes: "asana_work_id: asana-1",
      sync_collection: collection
    )
    asana_item = Asana::Task.create!(
      options: options.merge(service_name: "Asana:work"),
      title: "Buy milk", external_id: "asana-1", notes: "omnifocus_id: of-1",
      sync_collection: collection
    )
    [omnifocus_item, asana_item].each do |item|
      item.update_columns(
        source_service_name: nil,
        source_service_instance: nil,
        first_observed_at: nil,
        last_observed_at: nil
      )
    end
    collection.update_columns(
      mapping_method: nil,
      mapping_confidence: nil,
      mapping_metadata: nil,
      mapping_established_at: nil,
      mapping_last_observed_at: nil
    )
    collection
  end

  it "runs the provenance backfill first, then enqueues baseline rows for the resolved identities" do
    create_legacy_pair

    expect { backfill_task.invoke }.to output(/Baseline backfill:/).to_stdout

    rows = OutboxEntry.where(record_kind: "item")
    expect(rows.map(&:service_instance)).to contain_exactly("omnifocus:default", "asana:work")
    expect(rows.map(&:record_kind)).to all(eq("item"))

    mapping_rows = OutboxEntry.where(record_kind: "mapping")
    expect(mapping_rows.count).to eq(2)
    expect(mapping_rows.map { |row| row.payload["mapping_confidence"] }).to all(eq("confirmed"))
  end

  it "is safe to run multiple times" do
    create_legacy_pair

    backfill_task.invoke
    first_run = OutboxEntry.order(:id).to_a.map { |row| [row.idempotency_key, row.payload] }
    backfill_task.reenable

    expect { backfill_task.invoke }.to output(/Baseline backfill:/).to_stdout

    expect(OutboxEntry.order(:id).to_a.map { |row| [row.idempotency_key, row.payload] }).to eq(first_run)
  end

  it "summarizes without enqueuing anything and warns when provenance is pending" do
    SyncCollection.create!(title: "Unmapped")

    expect do
      dry_run_task.invoke
    end.to output(/Baseline backfill \(dry run\):/).to_stdout
                                                   .and output(/task_bridge:backfill_sync_provenance/).to_stderr

    expect(OutboxEntry.count).to eq(0)
  end

  it "does not warn on a dry run when provenance is fully backfilled" do
    Omnifocus::Task.create!(
      options: options.merge(service_name: "Omnifocus"),
      title: "Buy milk", external_id: "of-2"
    )

    expect do
      dry_run_task.invoke
    end.to output(/items: 1 considered, 1 enqueued/).to_stdout
                                                    .and output("").to_stderr

    expect(OutboxEntry.count).to eq(0)
  end
end
