# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "task_bridge:backfill_outbox_baseline tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:backfill_outbox_baseline")
  end

  let(:summary) { { items: { by_service: { "asana" => 1 }, skipped: 0 }, mappings: { by_confidence: {}, withheld_low_confidence: 0, skipped: 0 } } }

  describe "task_bridge:backfill_outbox_baseline" do
    let(:task) { Rake::Task["task_bridge:backfill_outbox_baseline"] }

    before { task.reenable }

    it "runs the backfill for real and reports the summary" do
      allow(SyncBackfill::OutboxBaseline).to receive(:run!).with(no_args).and_return(summary)

      expect { task.invoke }.to output(/Outbox baseline backfill complete/).to_stdout
      expect(SyncBackfill::OutboxBaseline).to have_received(:run!).with(no_args)
    end
  end

  describe "task_bridge:backfill_outbox_baseline_dry_run" do
    let(:task) { Rake::Task["task_bridge:backfill_outbox_baseline_dry_run"] }

    before { task.reenable }

    it "previews the backfill without writing anything" do
      allow(SyncBackfill::OutboxBaseline).to receive(:run!).with(dry_run: true).and_return(summary)

      expect { task.invoke }.to output(/Outbox baseline backfill dry run \(no rows written\)/).to_stdout
      expect(SyncBackfill::OutboxBaseline).to have_received(:run!).with(dry_run: true)
    end
  end
end
