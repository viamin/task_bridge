# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:backfill_outbox_baseline tasks" do
  include ActiveSupport::Testing::TimeHelpers

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_outbox_baseline")
  end

  let(:task) { Rake::Task["task_bridge:backfill_outbox_baseline"] }
  let(:dry_run_task) { Rake::Task["task_bridge:backfill_outbox_baseline_dry_run"] }
  let(:observed_at) { Time.zone.parse("2026-10-05T10:00:00Z") }

  before do
    task.reenable
    dry_run_task.reenable
    Rake::Task["task_bridge:backfill_sync_provenance"].reenable
    allow(SyncBackfill::SourceProvenance).to receive(:run!).and_call_original
    allow(SyncBackfill::OutboxBaseline).to receive(:run!).and_call_original
    allow(SyncBackfill::OutboxBaseline).to receive(:preview).and_call_original
    travel_to(observed_at)
  end

  after { travel_back }

  it "runs the provenance backfill before seeding outbox baseline rows" do
    Omnifocus::Task.create!(title: "Buy milk", external_id: "of-1",
                            options: { services: [], primary: "Omnifocus", tags: [] })

    task.invoke

    expect(SyncBackfill::SourceProvenance).to have_received(:run!)
    expect(OutboxEntry.where(record_kind: "item", external_id: "of-1")).to exist
    expect(SyncBackfill::OutboxBaseline).to have_received(:run!)
  end

  it "prints the backfill summary" do
    SyncCollection.create!(title: "Release checklist", mapping_method: "source_sync_id", mapping_confidence: "high")

    expect { task.invoke }.to output(/Items: 0 snapshots planned/).to_stdout
  end

  it "previews without writing outbox rows or running the provenance backfill" do
    Asana::Task.create!(title: "Buy milk", external_id: "1201",
                        options: { service_name: "Asana:work", services: [], primary: "Omnifocus", tags: [] })

    expect { dry_run_task.invoke }
      .to output(/Items: 1 snapshots planned.*by service: asana=1/m).to_stdout
      .and output(/Dry run only: nothing was enqueued/).to_stderr

    expect(SyncBackfill::SourceProvenance).not_to have_received(:run!)
    expect(SyncBackfill::OutboxBaseline).to have_received(:preview)
    expect(SyncBackfill::OutboxBaseline).not_to have_received(:run!)
    expect(OutboxEntry.count).to eq(0)
  end
end
