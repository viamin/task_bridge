# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill tasks", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill")
  end

  let(:backfill_task) { Rake::Task["task_bridge:outbox:backfill"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_dry_run"] }
  let(:item_class) do
    stub_const("OutboxBackfillTaskItem", Class.new(Base::SyncItem) do
      def self.attribute_map
        {}
      end

      def provider
        "Asana"
      end

      def external_data
        {}
      end
    end)
  end
  let(:collection) do
    SyncCollection.create!(title: "Buy milk", mapping_method: "source_sync_id", mapping_confidence: "high")
  end

  before do
    backfill_task.reenable
    dry_run_task.reenable
    allow(SyncBackfill::BaselineOutbox).to receive(:run!).and_call_original
    item_class
    collection
    item_class.create!(
      options: options.merge(service_name: "Asana:work"),
      title: "Buy milk",
      external_id: "asana-123",
      notes: "",
      sync_collection: collection
    )
  end

  it "seeds baseline rows idempotently" do
    expect { backfill_task.invoke }.to output(/items: enqueued 1/).to_stdout
    backfill_task.reenable
    expect { backfill_task.invoke }.not_to(change { OutboxEntry.count })

    expect(SyncBackfill::BaselineOutbox).to have_received(:run!).twice
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(1)
  end

  it "previews the backfill without writing outbox rows" do
    expect { dry_run_task.invoke }.to output(/dry run/).to_stdout

    expect(SyncBackfill::BaselineOutbox).to have_received(:run!).with(dry_run: true)
    expect(OutboxEntry.count).to eq(0)
  end
end
