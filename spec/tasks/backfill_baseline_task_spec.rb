# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill_baseline tasks", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_baseline_dry_run"] }
  let(:test_item_class) do
    stub_const("BackfillBaselineTaskItem", Class.new(Base::SyncItem) do
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
  let(:peer_item_class) do
    stub_const("BackfillBaselinePeerItem", Class.new(Base::SyncItem) do
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
    test_item_class
    peer_item_class
  end

  it "enqueues baseline rows idempotently and prints the summary" do
    collection = SyncCollection.create!(title: "Buy milk")
    test_item_class.create!(
      options: options.merge(service_name: "Asana:work"),
      title: "Buy milk",
      external_id: "asana-1",
      notes: "omnifocus_id: of-1",
      sync_collection: collection
    )
    peer_item_class.create!(
      options: options.merge(service_name: "Omnifocus"),
      title: "Buy milk",
      external_id: "of-1",
      notes: "asana_work_id: asana-1",
      sync_collection: collection
    )

    expect { task.invoke }.to output(/Baseline backfill at /).to_stdout
    expect(OutboxEntry.where(record_kind: "item").count).to eq(2)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(2)
    task.reenable

    expect { task.invoke }.to output(/2 already backfilled/).to_stdout
    expect(OutboxEntry.count).to eq(4)
  end

  it "previews without writing anything" do
    test_item_class.create!(
      options: options.merge(service_name: "Asana:work"),
      title: "Buy milk",
      external_id: "asana-1"
    )

    expect { dry_run_task.invoke }.to output(/Baseline backfill \(dry run\)/).to_stdout
    expect(OutboxEntry.count).to eq(0)
  end
end
