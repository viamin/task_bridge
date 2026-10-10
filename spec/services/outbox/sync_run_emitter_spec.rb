# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunEmitter do
  let(:started_at) { Time.zone.parse("2026-10-05T19:20:00Z") }
  let(:finished_at) { Time.zone.parse("2026-10-05T19:21:05Z") }
  let(:summary) do
    {
      service: "Asana:work",
      status: "success",
      items_synced: 12,
      last_attempted: "2026-10-05T19:20:00.000000Z",
      last_successful: "2026-10-05T19:21:05.000000Z",
      last_failed: nil,
      detail: "12 items processed"
    }
  end
  let(:logs) do
    [
      {
        "service" => "Asana:work",
        "status" => "success",
        "items_synced" => 6,
        "touched_collection_ids" => [84, 91]
      },
      {
        "service" => "Asana:work",
        "items_synced" => 6,
        "last_successful" => "2026-10-05T19:21:05.000000Z",
        "touched_collection_ids" => [91]
      }
    ]
  end

  def emit
    described_class.emit_for_run(summary:, logs:, service_name: "Asana:work",
                                 started_at:, finished_at:)
  end

  def sync_run_rows
    OutboxEntry.where(record_kind: "sync_run")
  end

  it "enqueues one sync_run row with the RDR #215 summary shape" do
    emit

    row = sync_run_rows.sole
    expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:work:sync-run-20261005T192000Z-asana")
    expect(row.service_type).to eq("asana")
    expect(row.service_instance).to eq("asana:work")
    expect(row.observed_at).to eq(finished_at)
    expect(row.payload).to include(
      "contract_version" => 1,
      "sync_run_id" => "sync-run-20261005T192000Z-asana",
      "service_type" => "asana",
      "service_instance" => "asana:work",
      "started_at" => "2026-10-05T19:20:00.000000Z",
      "finished_at" => "2026-10-05T19:21:05.000000Z",
      "last_attempted_at" => "2026-10-05T19:20:00.000000Z",
      "last_successful_at" => "2026-10-05T19:21:05.000000Z",
      "last_failed_at" => nil,
      "status" => "success",
      "items_synced" => 12,
      "touched_collection_ids" => [84, 91],
      "detail" => "12 items processed",
      "error" => nil
    )
  end

  it "is idempotent for the same run" do
    emit
    emit

    expect(sync_run_rows.count).to eq(1)
  end

  it "carries error details for failed runs" do
    summary.merge!(
      status: "failed",
      last_successful: nil,
      last_failed: "2026-10-05T19:21:05.000000Z",
      detail: "ProviderError: 401 unauthorized"
    )
    logs << {
      "service" => "Asana:work",
      "status" => "failed",
      "items_synced" => 0,
      "error_class" => "ProviderError",
      "error_message" => "401 unauthorized"
    }

    emit

    payload = sync_run_rows.sole.payload
    expect(payload["status"]).to eq("failed")
    expect(payload["last_failed_at"]).to eq("2026-10-05T19:21:05.000000Z")
    expect(payload["error"]).to eq(
      "class" => "ProviderError",
      "message" => "401 unauthorized",
      "retryable" => true
    )
  end

  it "publishes nothing for skipped or idle services" do
    summary[:status] = "skipped"
    expect(emit).to be_nil

    summary[:status] = "idle"
    expect(emit).to be_nil

    expect(sync_run_rows).to be_empty
  end

  it "truncates detail and error messages to bounded operational text" do
    summary[:detail] = "x" * 500

    emit

    expect(sync_run_rows.sole.payload["detail"].length).to eq(described_class::DETAIL_LIMIT)
  end

  it "identifies unqualified service names without an instance segment" do
    described_class.emit_for_run(summary:, logs:, service_name: "Github",
                                 started_at:, finished_at:)

    row = sync_run_rows.sole
    expect(row.service_type).to eq("github")
    expect(row.service_instance).to eq("github")
    expect(row.idempotency_key).to start_with("tb:v1:sync_run:github:sync-run-20261005T192000Z-github")
  end
end
