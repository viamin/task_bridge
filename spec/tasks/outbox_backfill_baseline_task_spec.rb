# frozen_string_literal: true

require "rails_helper"
require "rake"
require "stringio"

RSpec.describe "task_bridge:outbox:backfill_baseline tasks" do
  include ActiveSupport::Testing::TimeHelpers

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_bridge:outbox:backfill_baseline")
  end

  let(:backfill_task) { Rake::Task["task_bridge:outbox:backfill_baseline"] }
  let(:dry_run_task) { Rake::Task["task_bridge:outbox:backfill_baseline_dry_run"] }
  let(:created_at) { Time.zone.parse("2026-09-01T09:00:00Z") }
  let(:base_options) { { quiet: true, pretend: false, services: [], primary: "Omnifocus", tags: [] } }
  let!(:data) do
    travel_to(created_at) do
      collection = SyncCollection.create!(title: "Buy milk")
      omnifocus = Omnifocus::Task.create!(
        title: "Buy milk", external_id: "of-77", notes: "asana_id: asana-123", sync_collection: collection
      )
      asana = Asana::Task.create!(
        title: "Buy milk", external_id: "asana-123", notes: "omnifocus_id: of-77", sync_collection: collection
      )
      github = Github::Issue.create!(title: "Release checklist", external_id: "issue-42",
                                     options: base_options.merge(service_name: "Github:repo-1"))
      { collection:, omnifocus_item: omnifocus, asana_item: asana, github_item: github }
    end
  end

  before do
    backfill_task.reenable
    dry_run_task.reenable
  end

  def capture_stdout
    original = $stdout
    captured = StringIO.new
    $stdout = captured
    yield
    captured.string
  ensure
    $stdout = original
  end

  it "enqueues baseline rows and prints the summary" do
    output = travel_to(Time.zone.parse("2026-10-10T12:00:00Z")) { capture_stdout { backfill_task.invoke } }

    expect(output).to include("Baseline items: 3 total, 3 enqueued, 0 skipped")
    expect(output).to include("omnifocus: 1 enqueued")
    expect(output).to include("Baseline mappings: 2 memberships, 2 enqueued, 0 withheld")
    expect(output).to include("confidence high: 2")
    expect(output).to include("Rerunning the backfill is safe")
    expect(OutboxEntry.where(record_kind: "item").count).to eq(3)
    expect(OutboxEntry.where(record_kind: "mapping").count).to eq(2)
  end

  it "prints the dry-run summary without writing anything" do
    output = travel_to(Time.zone.parse("2026-10-10T12:00:00Z")) { capture_stdout { dry_run_task.invoke } }

    expect(output).to include("Baseline items: 3 total, 3 would enqueue, 0 skipped")
    expect(output).to include("Dry run: no rows were written")
    expect(output).not_to include("Rerunning the backfill is safe")
    expect(OutboxEntry.count).to eq(0)
    expect(data[:collection].reload.mapping_method).to be_nil
  end

  it "lists withheld low-confidence memberships only in the dry run" do
    data[:asana_item].update_columns(notes: nil, title: "Totally different")
    data[:omnifocus_item].update_columns(notes: nil)

    dry_output = capture_stdout { dry_run_task.invoke }
    wet_output = capture_stdout { backfill_task.invoke }

    expect(dry_output).to include("Withheld low-confidence memberships")
    expect(dry_output).to include("omnifocus:of-77")
    expect(wet_output).not_to include("Withheld low-confidence memberships")
    expect(wet_output).to include("Baseline mappings: 2 memberships, 0 enqueued, 2 withheld")
  end
end
