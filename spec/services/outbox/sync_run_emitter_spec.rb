# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunEmitter do
  let(:started_at) { Time.zone.parse("2026-10-05T12:00:00Z") }
  let(:finished_at) { Time.zone.parse("2026-10-05T12:01:05Z") }
  let(:summary) do
    {
      service: "Asana:work",
      status: "success",
      items_synced: 12,
      last_attempted: "2026-10-05T12:00:00.000000Z",
      last_successful: "2026-10-05T12:01:05.000000Z",
      last_failed: nil,
      detail: "12 items processed"
    }
  end
  let(:logs) do
    [
      {
        "service" => "Asana:work",
        "status" => "success",
        "items_synced" => 12,
        "touched_collection_ids" => [84, 91]
      }
    ]
  end

  def emit(service_name: "Asana:work", summary: self.summary, logs: self.logs)
    described_class.emit_service_run(
      service_name:, summary:, logs:, started_at:, finished_at:
    )
  end

  def sync_run_rows
    OutboxEntry.where(record_kind: "sync_run")
  end

  it "enqueues one contract-shaped sync_run row for a successful service run" do
    emit

    expect(sync_run_rows.length).to eq(1)
    row = sync_run_rows.first
    expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:work:sync-run-20261005T120000Z-asana_work")
    expect(row.service_type).to eq("asana")
    expect(row.service_instance).to eq("asana:work")
    expect(row.observed_at).to eq(started_at)
    expect(row.payload).to include(
      "contract_version" => 1,
      "sync_run_id" => "sync-run-20261005T120000Z-asana_work",
      "service_type" => "asana",
      "service_instance" => "asana:work",
      "started_at" => "2026-10-05T12:00:00.000000Z",
      "finished_at" => "2026-10-05T12:01:05.000000Z",
      "last_attempted_at" => "2026-10-05T12:00:00.000000Z",
      "last_successful_at" => "2026-10-05T12:01:05.000000Z",
      "status" => "success",
      "items_synced" => 12,
      "touched_collection_ids" => [84, 91],
      "detail" => "12 items processed"
    )
    expect(row.payload["error"]).to be_nil
    expect(row.payload["last_failed_at"]).to be_nil
  end

  it "derives bare identity for services without an instance segment" do
    emit(service_name: "Asana")

    row = sync_run_rows.first
    expect(row.service_instance).to eq("asana")
    expect(row.payload["service_instance"]).to eq("asana")
    expect(row.payload["sync_run_id"]).to eq("sync-run-20261005T120000Z-asana")
    expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:sync-run-20261005T120000Z-asana")
  end

  it "publishes failed runs with a sanitized error and failure timestamps" do
    emit(
      summary: summary.merge(
        status: "failed",
        last_successful: nil,
        last_failed: "2026-10-05T12:01:05.000000Z"
      ),
      logs: logs + [
        {
          "service" => "Asana:work",
          "status" => "failed",
          "error_class" => "ProviderError",
          "error_message" => "401 unauthorized\nAuthorization: Bearer eyJhbGciOi.eyJzZWNyZXQifQ"
        }
      ]
    )

    payload = sync_run_rows.first.payload
    expect(payload["status"]).to eq("failed")
    expect(payload["last_failed_at"]).to eq("2026-10-05T12:01:05.000000Z")
    expect(payload["last_successful_at"]).to be_nil
    expect(payload["error"]).to include(
      "class" => "ProviderError",
      "message" => "401 unauthorized [redacted]",
      "retryable" => true
    )
  end

  it "defaults the error class when logs carry no structured failure" do
    emit(summary: summary.merge(status: "failed"), logs: [])

    expect(sync_run_rows.first.payload["error"]).to include(
      "class" => "ProviderError",
      "retryable" => true
    )
  end

  it "publishes nothing for skipped or idle services" do
    %w[skipped idle].each { |status| emit(summary: summary.merge(status:)) }

    expect(sync_run_rows).to be_empty
  end

  it "is idempotent for the same run" do
    emit
    emit

    expect(sync_run_rows.length).to eq(1)
  end

  it "enqueues nothing during pretend runs" do
    Thread.current[:global_options] = { pretend: true }

    emit

    expect(sync_run_rows).to be_empty
  end

  it "truncates and collapses overly long operational detail" do
    emit(summary: summary.merge(detail: "line one\nline two #{'x' * 2_000}"))

    expect(sync_run_rows.first.payload["detail"]).to eq("line one line two #{'x' * 979}...")
  end

  it "isolates outbox write failures instead of failing the run" do
    allow(OutboxEntry).to receive(:enqueue).and_raise(ActiveRecord::ActiveRecordError, "outbox unavailable")

    expect do
      expect { emit }.not_to raise_error
    end.to output(/dropping sync run summary for Asana:work/).to_stderr
  end
end
