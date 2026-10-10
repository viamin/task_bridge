# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:backfill_baseline_observations task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_baseline_observations")
  end

  let(:task) { Rake::Task["task_bridge:backfill_baseline_observations"] }
  let(:item_class) do
    stub_const("BaselineTaskItem", Class.new(Base::SyncItem) do
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
  let(:collection) { SyncCollection.create!(title: "Buy milk") }

  before do
    task.reenable
    item_class
    item_class.create!(options: { quiet: true, pretend: false, tags: [], services: [], primary: "Omnifocus" },
                       title: "Buy milk", external_id: "asana-1", sync_collection: collection)
    collection.update_columns(mapping_confidence: "high", mapping_method: "source_sync_id")
  end

  after { ENV.delete("DRY_RUN") }

  it "seeds baseline observations and prints the summary" do
    output = capture_stdout { task.invoke }

    expect(OutboxEntry.where(record_kind: "observation").count).to eq(1)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(1)
    expect(output).to include("Baseline observation backfill complete:")
    expect(output).to include("items: 1 baseline, 0 skipped incomplete, 0 already observed")
    expect(output).to include("items by service: asana=1")
    expect(output).to include("mappings: 1 members published, 0 members withheld")
  end

  it "previews counts without writing anything in dry-run mode" do
    ENV["DRY_RUN"] = "1"

    output = capture_stdout { task.invoke }

    expect(OutboxEntry.count).to eq(0)
    expect(output).to include("Baseline observation backfill (DRY RUN — nothing was written):")
    expect(output).to include("items: 1 baseline")
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
end
