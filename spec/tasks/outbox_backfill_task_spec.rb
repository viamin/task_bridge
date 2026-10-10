# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:outbox:backfill_baseline task", :full_options do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }

  let!(:item) do
    Asana::Task.create!(
      options: options.merge(service_name: "Asana:work"),
      title: "Buy milk",
      external_id: "asana-1"
    )
  end

  before do
    task.reenable
    allow(SyncBackfill::OutboxBaseline).to receive(:run!).and_call_original
  end

  after { ENV.delete("DRY_RUN") }

  it "runs the baseline backfill and prints the summary" do
    expect { task.invoke }
      .to output(/Backfill baseline \(complete\): items 1 enqueued \(asana: 1\)/).to_stdout

    expect(SyncBackfill::OutboxBaseline).to have_received(:run!).with(dry_run: false)
    expect(OutboxEntry.where(record_kind: "item")).to contain_exactly(
      an_object_having_attributes(external_id: "asana-1", service_instance: "asana:work")
    )
  end

  it "previews without writing anything when DRY_RUN is set" do
    ENV["DRY_RUN"] = "1"

    expect { task.invoke }
      .to output(/Backfill baseline \(dry run\): items 1 enqueued \(asana: 1\)/).to_stdout

    expect(SyncBackfill::OutboxBaseline).to have_received(:run!).with(dry_run: true)
    expect(OutboxEntry.count).to eq(0)
  end
end
