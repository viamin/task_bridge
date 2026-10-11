# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill_baseline tasks", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_baseline_dry_run"] }
  let(:item_class) do
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
  let(:peer_class) do
    stub_const("BackfillBaselineTaskPeerItem", Class.new(Base::SyncItem) do
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
  let(:collection) { SyncCollection.create!(title: "Buy milk") }

  before do
    task.reenable
    dry_run_task.reenable
    item_class
    peer_class
    item_class.create!(
      options: options.merge(service_name: "Asana:work"),
      title: "Buy milk",
      external_id: "asana-123",
      notes: "omnifocus_id: of-456",
      sync_collection: collection
    )
    peer_class.create!(
      options: options.merge(service_name: "Omnifocus"),
      title: "Buy milk",
      external_id: "of-456",
      notes: "asana_work_id: asana-123",
      sync_collection: collection
    )
  end

  it "enqueues the baseline and is idempotent across repeated invocations" do
    expect { task.invoke }.to output(
      /Baseline backfill: 2 item snapshots enqueued \(0 already backfilled, 0 incomplete\), 2 mapping rows enqueued/
    ).to_stdout

    task.reenable
    expect { task.invoke }.to output(/0 item snapshots enqueued \(2 already backfilled/).to_stdout

    expect(OutboxEntry.where(record_kind: "item").count).to eq(2)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(2)
  end

  it "summarizes a dry run without writing anything" do
    expect { dry_run_task.invoke }.to output(
      /Baseline backfill dry run: would enqueue 2 item snapshots \(0 incomplete\) and 2 mapping rows/
    ).to_stdout

    dry_run_task.reenable
    expect { dry_run_task.invoke }.to output(/Item snapshots by service: asana=1, omnifocus=1/).to_stdout

    expect(OutboxEntry.count).to eq(0)
  end

  it "lists withheld low-confidence collections in the dry run" do
    orphan_collection = SyncCollection.create!(title: "Orphan")
    orphan_collection.sync_items << peer_class.create!(
      options: options.merge(service_name: "Omnifocus"),
      title: "Orphan",
      external_id: "of-999"
    )

    expect { dry_run_task.invoke }.to output(
      /would enqueue 3 item snapshots \(0 incomplete\) and 2 mapping rows \(1 would be withheld low confidence/
    ).to_stdout

    dry_run_task.reenable
    withheld_line = /Withheld low confidence: sync_collection #{orphan_collection.id} \(1 members, method: manual_backfill\) "Orphan"/
    expect { dry_run_task.invoke }.to output(withheld_line).to_stdout
  end
end
