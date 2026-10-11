# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill_baseline tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_baseline_dry_run"] }
  let(:task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }
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
  let(:options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }

  before do
    item_class
    task.reenable
    dry_run_task.reenable
    item_class.create!(options:, title: "Buy milk", external_id: "asana-1", source_service_name: "Asana")
  end

  it "previews without writing, then backfills, then reruns as a no-op" do
    expect { dry_run_task.invoke }.to output(/dry run — nothing was written.*would enqueue 1/m).to_stdout
    expect(OutboxEntry.count).to eq(0)

    expect { task.invoke }.to output(/Baseline backfill \(completed\)/).to_stdout
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)

    task.reenable
    expect { task.invoke }.to output(/skipped: already_backfilled 1/).to_stdout
    expect(OutboxEntry.where(record_kind: "item").count).to eq(1)
  end
end
