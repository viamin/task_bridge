# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunEmitter do
  let(:sync_started_at) { "2026-10-05T19:20:00.123456Z" }
  let(:finished_at) { Time.zone.parse("2026-10-05T19:21:05.987654Z") }

  def run_summary(overrides = {})
    {
      service: "Asana:work",
      status: "success",
      items_synced: 12,
      last_attempted: sync_started_at,
      last_successful: sync_started_at,
      last_failed: nil,
      detail: "12 items processed"
    }.merge(overrides)
  end

  def emit(summary = run_summary, logs: [])
    described_class.emit_for_run(summary, logs:, sync_started_at:, finished_at:)
  end

  it "enqueues one sync_run row with the RDR summary schema" do
    emit(logs: [{ "touched_collection_ids" => [84, 91] }, { "touched_collection_ids" => [84] }])

    row = OutboxEntry.find_by(record_kind: "sync_run")
    expect(row).to have_attributes(
      service_type: "asana",
      service_instance: "asana:work",
      observed_at: finished_at,
      payload_version: 1
    )
    expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:work:sync-run-#{sync_started_at}")
    expect(row.payload).to include(
      "contract_version" => 1,
      "sync_run_id" => "sync-run-#{sync_started_at}",
      "service_type" => "asana",
      "service_instance" => "asana:work",
      "started_at" => "2026-10-05T19:20:00.123456Z",
      "finished_at" => "2026-10-05T19:21:05.987654Z",
      "last_attempted_at" => "2026-10-05T19:20:00.123456Z",
      "last_successful_at" => "2026-10-05T19:20:00.123456Z",
      "last_failed_at" => nil,
      "status" => "success",
      "items_synced" => 12,
      "touched_collection_ids" => [84, 91],
      "detail" => "12 items processed",
      "error" => nil
    )
  end

  it "is idempotent for the same run" do
    2.times { emit }

    expect(OutboxEntry.where(record_kind: "sync_run").count).to eq(1)
  end

  it "reports a failed run with an isolated error object" do
    emit(
      run_summary(status: "failed", last_successful: nil,
                  last_failed: "2026-10-05T19:21:05.000000Z", detail: "ProviderError: 401 unauthorized"),
      logs: [{ "status" => "failed", "error_class" => "ProviderError", "error_message" => "401 unauthorized" }]
    )

    payload = OutboxEntry.find_by(record_kind: "sync_run").payload
    expect(payload).to include("status" => "failed", "last_failed_at" => "2026-10-05T19:21:05.000000Z")
    expect(payload["error"]).to eq("class" => "ProviderError", "message" => "401 unauthorized", "retryable" => false)
  end

  it "omits the error object when logs carry no structured error fields" do
    emit(run_summary(status: "failed", last_successful: nil, last_failed: "2026-10-05T19:21:05.000000Z"), logs: [])

    expect(OutboxEntry.find_by(record_kind: "sync_run").payload["error"]).to be_nil
  end

  it "publishes nothing for skipped or idle services" do
    emit(run_summary(status: "skipped", last_successful: nil))
    emit(run_summary(status: "idle", last_attempted: nil, last_successful: nil))

    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
  end

  it "publishes nothing for a skipped service replaying stale previous-run state" do
    stale = "2026-10-04T09:00:00.000000Z"
    emit(run_summary(last_attempted: stale, last_successful: stale))

    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
  end

  it "never raises when the outbox write fails" do
    allow(OutboxEntry).to receive(:enqueue).and_raise(ActiveRecord::StatementInvalid, "database is locked")

    expect { emit }
      .to output(/dropping sync run for asana:work/).to_stderr
      .and(change { OutboxEntry.count }.by(0))
  end
end
