# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunEmitter do
  let(:now) { Time.zone.parse("2026-10-05T12:00:00Z") }
  let(:run_started_at) { "2026-10-05T10:00:00.000000Z" }
  let(:base_summary) do
    {
      service: "Asana",
      status: "success",
      items_synced: 2,
      last_attempted: run_started_at,
      last_successful: "2026-10-05T10:05:00.000000Z",
      last_failed: nil,
      detail: "2 items processed"
    }
  end

  def emit(summary_overrides = {}, logs: [])
    described_class.emit_for(
      service_name: summary_overrides.fetch(:service, "Asana"),
      summary: base_summary.merge(summary_overrides),
      logs:,
      now:
    )
  end

  def sync_run_rows
    OutboxEntry.where(record_kind: "sync_run")
  end

  it "enqueues one row for a successful run with the RDR summary shape" do
    logs = [{ "service" => "Asana", "items_synced" => 2, "touched_collection_ids" => [84, 91, 84] }]

    emit(logs:)
    expect(sync_run_rows.count).to eq(1)

    row = sync_run_rows.first
    expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:sync-run-20261005T100000Z-asana")
    expect(row.service_type).to eq("asana")
    expect(row.service_instance).to eq("asana")
    expect(row.observed_at).to eq(now)
    expect(row.payload).to include(
      "contract_version" => 1,
      "sync_run_id" => "sync-run-20261005T100000Z-asana",
      "service_type" => "asana",
      "service_instance" => "asana",
      "started_at" => run_started_at,
      "finished_at" => "2026-10-05T12:00:00.000000Z",
      "last_attempted_at" => run_started_at,
      "last_successful_at" => "2026-10-05T10:05:00.000000Z",
      "status" => "success",
      "items_synced" => 2,
      "touched_collection_ids" => [84, 91],
      "detail" => "2 items processed"
    )
    expect(row.payload).not_to have_key("error")
  end

  it "enqueues a failed run with a structured terminal error" do
    logs = [
      {
        "service" => "Github",
        "status" => "failed",
        "last_attempted" => run_started_at,
        "last_failed" => "2026-10-05T10:00:02.000000Z",
        "error_class" => "ProviderError",
        "error_message" => "401 unauthorized"
      }
    ]

    emit({ service: "Github", status: "failed", items_synced: 0, last_successful: nil,
           last_failed: "2026-10-05T10:00:02.000000Z", detail: "ProviderError: 401 unauthorized" },
         logs:)
    row = sync_run_rows.first

    expect(row.payload).to include(
      "status" => "failed",
      "last_failed_at" => "2026-10-05T10:00:02.000000Z",
      "error" => { "class" => "ProviderError", "message" => "401 unauthorized", "retryable" => false }
    )
    expect(row.payload).not_to have_key("last_successful_at")
  end

  it "omits the error when a failed summary carries no structured failure" do
    emit({ status: "failed", detail: "Failure recorded" })

    expect(sync_run_rows.first.payload).not_to have_key("error")
  end

  it "does not enqueue for skipped or idle services" do
    emit({ status: "skipped", detail: "Sync not required" })
    emit({ status: "idle", detail: "No work performed" })

    expect(sync_run_rows).to be_empty
  end

  it "qualifies service identity with the configured instance name" do
    emit({ service: "Asana:work" })

    row = sync_run_rows.first
    expect(row.service_instance).to eq("asana:work")
    expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:work:sync-run-20261005T100000Z-asana_work")
  end

  it "is idempotent for the same run summary" do
    2.times { emit }

    expect(sync_run_rows.count).to eq(1)
  end

  it "falls back to the conclusion time when the run start is unknown" do
    emit({ last_attempted: nil })

    row = sync_run_rows.first
    expect(row.payload["started_at"]).to eq("2026-10-05T12:00:00.000000Z")
    expect(row.payload["sync_run_id"]).to eq("sync-run-20261005T120000Z-asana")
  end

  it "keeps emission isolated when the outbox write fails" do
    allow(OutboxEntry).to receive(:enqueue).and_raise(ActiveRecord::ActiveRecordError, "simulated outbox failure")

    expect do
      expect do
        emit
      end.to output(/dropping sync run for Asana/).to_stderr
    end.not_to raise_error
  end
end
