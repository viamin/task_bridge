# frozen_string_literal: true

require "rails_helper"

# Red specs for the RDR #215 "Sync-Run Summary Schema" producer, written
# during the #214 final audit: the `sync_run` record kind is supported
# end to end (OutboxEntry validation, Outbox::IdempotencyKey's
# `tb:v1:sync_run:...` format, WebPublisher::Batch's `sync_runs` array,
# and the Pact contract), and the producer (Outbox::SyncRunEmitter) plus
# its sync-task wiring in lib/tasks/sync.rake now enqueue rows on every
# successful or failed service run (see docs/epic-214-final-audit.md).
RSpec.describe "Outbox::SyncRunEmitter sync-run summary rows" do
  include ActiveSupport::Testing::TimeHelpers

  let(:finished_at) { Time.zone.parse("2026-10-05T10:05:00Z") }
  let(:started_at) { "2026-10-05T10:00:00.000000Z" }
  let(:options) { { sync_started_at: started_at, pretend: false } }
  let(:summary) do
    {
      service: "Asana:work",
      status: "success",
      items_synced: 12,
      last_attempted: started_at,
      last_successful: "2026-10-05T10:04:58.000000Z",
      last_failed: nil,
      detail: "12 items processed"
    }
  end
  let(:logs) do
    [{
      "service" => "Asana:work",
      "status" => "success",
      "items_synced" => 12,
      "last_attempted" => started_at,
      "last_successful" => started_at,
      "touched_collection_ids" => [91, 84, 91]
    }.stringify_keys]
  end

  def emit(service_name: summary[:service], summary: self.summary, logs: self.logs, options: self.options)
    travel_to(finished_at) do
      Outbox::SyncRunEmitter.emit_for_run(service_name:, summary:, logs:, options:)
    end
  end

  it "enqueues one sync-run summary row for a successful run" do
    emit

    row = OutboxEntry.find_by(record_kind: "sync_run")
    expect(row).to have_attributes(
      service_type: "asana",
      service_instance: "asana:work",
      observed_at: finished_at,
      payload_version: 1
    )
    expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:work:sync-run-20261005T100000Z-asana_work")
    expect(row.payload).to include(
      "contract_version" => 1,
      "sync_run_id" => "sync-run-20261005T100000Z-asana_work",
      "service_type" => "asana",
      "service_instance" => "asana:work",
      "started_at" => started_at,
      "finished_at" => "2026-10-05T10:05:00.000000Z",
      "last_attempted_at" => started_at,
      "last_successful_at" => "2026-10-05T10:04:58.000000Z",
      "last_failed_at" => nil,
      "status" => "success",
      "items_synced" => 12,
      "touched_collection_ids" => [84, 91],
      "detail" => "12 items processed",
      "error" => nil
    )
  end

  it "uses the bare service family when the service has no instance name" do
    emit(service_name: "Asana")

    row = OutboxEntry.find_by(record_kind: "sync_run")
    expect(row).to have_attributes(service_type: "asana", service_instance: "asana")
    expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:sync-run-20261005T100000Z-asana")
  end

  it "publishes failed runs with a structured error marked non-retryable" do
    emit(summary: summary.merge(
      status: "failed",
      last_successful: nil,
      last_failed: "2026-10-05T10:04:59.000000Z",
      detail: "ProviderError: 401 unauthorized"
    ), logs: [logs.first.merge(
      "status" => "failed",
      "error_class" => "ProviderError",
      "error_message" => "401 unauthorized"
    )])

    row = OutboxEntry.find_by(record_kind: "sync_run")
    expect(row.payload).to include(
      "status" => "failed",
      "last_successful_at" => nil,
      "last_failed_at" => "2026-10-05T10:04:59.000000Z",
      "error" => { "class" => "ProviderError", "message" => "401 unauthorized", "retryable" => false }
    )
  end

  it "marks authorization-class failures non-retryable" do
    emit(summary: summary.merge(status: "failed"), logs: [logs.first.merge(
      "status" => "failed",
      "error_class" => "Google::Apis::AuthorizationError",
      "error_message" => "credentials are no longer valid"
    )])

    expect(OutboxEntry.find_by(record_kind: "sync_run").payload.dig("error", "retryable")).to be(false)
  end

  it "uses the failing log when an earlier sync operation succeeded" do
    emit(
      summary: summary.merge(status: "failed"),
      logs: [
        logs.first,
        logs.first.merge(
          "status" => "failed",
          "error_class" => "ProviderError",
          "error_message" => "503 unavailable"
        )
      ]
    )

    expect(OutboxEntry.find_by(record_kind: "sync_run").payload["error"]).to eq(
      "class" => "ProviderError", "message" => "503 unavailable", "retryable" => true
    )
  end

  it "reads failed error details from symbol-keyed logs" do
    failed_log = {
      status: "failed",
      error_class: "ProviderError",
      error_message: "401 unauthorized"
    }
    emit(summary: summary.merge(status: "failed"), logs: [failed_log])

    expect(OutboxEntry.find_by(record_kind: "sync_run").payload["error"]).to eq(
      "class" => "ProviderError", "message" => "401 unauthorized", "retryable" => false
    )
  end

  it "ignores empty log entries when collecting touched collections" do
    emit(logs: [nil, logs.first])

    expect(OutboxEntry.find_by(record_kind: "sync_run").payload["touched_collection_ids"]).to eq([84, 91])
  end

  it "does not publish skipped or idle services" do
    aggregate_failures do
      emit(summary: summary.merge(status: "skipped"))
      emit(summary: summary.merge(status: "idle"))
      emit(service_name: "Asana:personal", summary: summary.merge(status: "skipped"))

      expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
    end
  end

  it "does not publish pretend runs" do
    emit(options: options.merge(pretend: true))

    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
  end

  it "does not publish when the run has no deterministic started_at" do
    emit(options: options.merge(sync_started_at: nil))

    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
  end

  it "does not publish when the run timestamp is invalid" do
    emit(options: options.merge(sync_started_at: "not-a-timestamp"))

    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
  end

  it "omits malformed optional summary timestamps" do
    emit(summary: summary.merge(last_successful: "not-a-timestamp"))

    expect(OutboxEntry.find_by(record_kind: "sync_run").payload["last_successful_at"]).to be_nil
  end

  it "re-emitting the same run dedupes to the stored row" do
    emit
    original = OutboxEntry.find_by(record_kind: "sync_run")

    expect { emit(summary: summary.merge(items_synced: 13)) }.not_to(change { OutboxEntry.where(record_kind: "sync_run").count })
    expect(OutboxEntry.find_by(record_kind: "sync_run").payload).to eq(original.payload)
  end

  it "bounds detail and error message length" do
    long_detail = ("a" * 600)
    emit(summary: summary.merge(status: "failed", detail: long_detail), logs: [logs.first.merge("error_message" => long_detail)])

    row = OutboxEntry.find_by(record_kind: "sync_run")
    expect(row.payload["detail"].length).to eq(500)
    expect(row.payload["error"]["message"].length).to eq(500)
  end

  it "redacts credentials and raw provider payloads from published operational text" do
    sensitive_detail = 'Authorization: Bearer detail-secret response: {"access_token":"response-secret"}'
    sensitive_error = 'cookie=session-secret access_token=error-secret payload: {"title":"provider response"}'
    emit(summary: summary.merge(status: "failed", detail: sensitive_detail), logs: [logs.first.merge(
      "status" => "failed", "error_message" => sensitive_error
    )])

    row = OutboxEntry.find_by(record_kind: "sync_run")
    published_text = [row.payload["detail"], row.payload.dig("error", "message")].join(" ")

    expect(published_text).to include("[REDACTED]")
    expect(published_text).not_to include("detail-secret", "response-secret", "session-secret", "error-secret", "provider response")
  end
end
