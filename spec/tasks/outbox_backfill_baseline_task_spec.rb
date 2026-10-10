# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill_baseline tasks", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_baseline_dry_run"] }
  let(:collection) { SyncCollection.create!(title: "Release checklist", mapping_method: "source_sync_id", mapping_confidence: "high") }
  let(:item_class) do
    stub_const("BackfillBaselineTaskItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Omnifocus"
      end

      def external_data
        {}
      end
    end)
  end

  before do
    task.reenable
    dry_run_task.reenable
    allow(SyncBackfill::OutboxBaseline).to receive(:run!).and_call_original
    item_class
  end

  it "seeds baseline item snapshots and mappings idempotently" do
    item = item_class.create!(
      options: options.merge(service_name: "Omnifocus"),
      title: "Buy milk",
      external_id: "of-1",
      sync_collection: collection
    )
    item.update_columns(last_observed_at: Time.zone.parse("2026-10-10T09:00:00Z"))

    task.invoke
    task.reenable

    expect(SyncBackfill::OutboxBaseline).to have_received(:run!)
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(1)

    task.invoke
    task.reenable

    expect(OutboxEntry.count).to eq(2)
    expect(OutboxEntry.where(record_kind: "item", external_id: "of-1").count).to eq(1)
  end

  it "previews the backfill without enqueuing anything" do
    item_class.create!(
      options: options.merge(service_name: "Omnifocus"),
      title: "Buy milk",
      external_id: "of-1"
    )

    expect { dry_run_task.invoke }.to output(/dry run — nothing was enqueued/).to_stdout
    expect(SyncBackfill::OutboxBaseline).to have_received(:run!).with(dry_run: true)
    expect(OutboxEntry.count).to eq(0)
  end
end
