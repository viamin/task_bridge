# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunEmitter do
  include ActiveSupport::Testing::TimeHelpers

  let(:started_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:finished_at) { Time.zone.parse("2026-10-05T10:01:05Z") }
  let(:summary) do
    {
      service: "Asana:work",
      status: "success",
      items_synced: 12,
      last_attempted: "2026-10-05T10:00:00.000000Z",
      last_successful: "2026-10-05T10:01:05.000000Z",
      last_failed: nil,
      detail: "12 items processed"
    }
  end
  let(:logs) do
    [
      {
        "service" => "Asana:work",
        "last_attempted" => "2026-10-05T10:00:00.000000Z",
        "last_successful" => "2026-10-05T10:01:05.000000Z",
        "items_synced" => 12,
        "touched_collection_ids" => [84, 91]
      }.stringify_keys
    ]
  end

  def emit
    travel_to(finished_at) do
      described_class.emit_for(service_name: "Asana:work", summary:, started_at:, logs:)
    end
  end

  def sync_run_rows
    OutboxEntry.where(record_kind: "sync_run")
  end

  it "enqueues one sync_run row with the RDR #215 summary shape" do
    emit

    expect(sync_run_rows.length).to eq(1)
    row = sync_run_rows.first
    expect(row.service_type).to eq("asana")
    expect(row.service_instance).to eq("asana:work")
    expect(row.observed_at).to eq(finished_at)
    expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:work:sync-run-20261005T100000Z-asana_work")
    expect(row.payload).to include(
      "contract_version" => 1,
      "sync_run_id" => "sync-run-20261005T100000Z-asana_work",
      "service_type" => "asana",
      "service_instance" => "asana:work",
      "started_at" => "2026-10-05T10:00:00.000000Z",
      "finished_at" => "2026-10-05T10:01:05.000000Z",
      "last_attempted_at" => "2026-10-05T10:00:00.000000Z",
      "last_successful_at" => "2026-10-05T10:01:05.000000Z",
      "status" => "success",
      "items_synced" => 12,
      "touched_collection_ids" => [84, 91],
      "detail" => "12 items processed"
    )
    expect(row.payload).not_to include("error")
    expect(row.payload).not_to include("last_failed_at")
  end

  it "is idempotent per service run" do
    emit
    emit

    expect(sync_run_rows.length).to eq(1)
  end

  it "carries a structured terminal error for failed runs" do
    summary.merge!(
      status: "failed",
      last_successful: nil,
      last_failed: "2026-10-05T10:01:05.000000Z",
      detail: "ProviderError: 401 unauthorized"
    )
    logs << {
      "service" => "Asana:work",
      "status" => "failed",
      "error_class" => "ProviderError",
      "error_message" => "401 unauthorized"
    }.stringify_keys

    emit

    row = sync_run_rows.first
    expect(row.payload["status"]).to eq("failed")
    expect(row.payload["last_failed_at"]).to eq("2026-10-05T10:01:05.000000Z")
    expect(row.payload).not_to include("last_successful_at")
    expect(row.payload["error"]).to eq(
      "class" => "ProviderError",
      "message" => "401 unauthorized",
      "retryable" => false
    )
  end

  it "does not publish skipped or idle services" do
    %w[skipped idle].each do |status|
      expect do
        described_class.emit_for(
          service_name: "Asana:work",
          summary: summary.merge(status:),
          started_at:,
          logs: logs
        )
      end.not_to change(sync_run_rows, :count)
    end
  end

  it "does not publish without a run scope" do
    expect do
      described_class.emit_for(service_name: "Asana:work", summary:, started_at: nil, logs:)
    end.not_to change(sync_run_rows, :count)
  end

  it "isolates outbox write failures instead of raising into the sync run" do
    allow(OutboxEntry).to receive(:enqueue).and_raise(ActiveRecord::ActiveRecordError, "simulated outbox failure")

    expect do
      expect do
        emit
      end.to output(/dropping sync run for Asana:work/).to_stderr
    end.not_to raise_error
    expect(sync_run_rows).to be_empty
  end

  it "enqueues nothing during pretend runs" do
    Thread.current[:global_options] = { pretend: true }

    expect(emit).to be_nil
    expect(sync_run_rows).to be_empty
  ensure
    Thread.current[:global_options] = nil
  end
end
