# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunEmitter do
  let(:started_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:finished_at) { Time.zone.parse("2026-10-05T10:01:05Z") }

  def emit(status:, service_name: "Asana", error: nil, extra_summary: {})
    summary = {
      "service" => service_name,
      "status" => status,
      "items_synced" => 12,
      "last_attempted" => "2026-10-05T10:00:00.000000Z",
      "last_successful" => "2026-10-05T10:01:05.000000Z",
      "last_failed" => nil,
      "detail" => "12 items processed",
      "touched_collection_ids" => [84, 91, 84, nil],
      "error" => error
    }.merge(extra_summary)
    described_class.emit_for(
      service_name:,
      summary:,
      started_at:,
      finished_at:
    )
  end

  def sync_run_rows
    OutboxEntry.where(record_kind: "sync_run")
  end

  it "enqueues one deterministic summary row for a successful run" do
    emit(status: "success")

    expect(sync_run_rows.count).to eq(1)
    row = sync_run_rows.first
    expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:sync-run-2026-10-05T10:00:00.000000Z")
    expect(row.service_type).to eq("asana")
    expect(row.service_instance).to eq("asana")
    expect(row.observed_at).to eq(finished_at)
    expect(row.payload).to include(
      "sync_run_id" => "sync-run-2026-10-05T10:00:00.000000Z",
      "service_type" => "asana",
      "service_instance" => "asana",
      "started_at" => "2026-10-05T10:00:00.000000Z",
      "finished_at" => "2026-10-05T10:01:05.000000Z",
      "last_attempted_at" => "2026-10-05T10:00:00.000000Z",
      "last_successful_at" => "2026-10-05T10:01:05.000000Z",
      "status" => "success",
      "items_synced" => 12,
      "touched_collection_ids" => [84, 91],
      "detail" => "12 items processed"
    )
    expect(row.payload["last_failed_at"]).to be_nil
    expect(row.payload["error"]).to be_nil
  end

  it "is idempotent for the same run" do
    2.times { emit(status: "success") }

    expect(sync_run_rows.count).to eq(1)
  end

  it "publishes failed runs with their error" do
    emit(status: "failed",
         extra_summary: { "last_successful" => nil, "last_failed" => "2026-10-05T10:01:05.000000Z" },
         error: { class: "ProviderError", message: "401 unauthorized", retryable: true })

    payload = sync_run_rows.first.payload
    expect(payload).to include(
      "status" => "failed",
      "last_successful_at" => nil,
      "last_failed_at" => "2026-10-05T10:01:05.000000Z"
    )
    expect(payload["error"]).to eq(
      "class" => "ProviderError",
      "message" => "401 unauthorized",
      "retryable" => false
    )
  end

  it "keeps error out of successful runs even when one is passed" do
    emit(status: "success", error: { class: "ProviderError", message: "stale failure detail" })

    expect(sync_run_rows.first.payload["error"]).to be_nil
  end

  it "does not publish skipped or idle runs" do
    emit(status: "skipped")
    emit(status: "idle")

    expect(sync_run_rows).to be_empty
  end

  it "qualifies the service instance without changing the service type" do
    emit(status: "success", service_name: "Asana:work")

    row = sync_run_rows.first
    expect(row.service_type).to eq("asana")
    expect(row.service_instance).to eq("asana:work")
    expect(row.payload["service_instance"]).to eq("asana:work")
  end
end
