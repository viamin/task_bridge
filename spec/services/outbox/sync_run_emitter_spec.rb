# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunEmitter do
  let(:service_name) { "Asana:work" }
  let(:finished_at) { Time.zone.parse("2026-10-05T10:05:00Z") }
  let(:base_summary) do
    {
      service: service_name,
      status: "success",
      items_synced: 3,
      last_attempted: "2026-10-05T10:00:00.000000Z",
      last_successful: "2026-10-05T10:00:00.000000Z",
      last_failed: nil,
      detail: "3 items processed"
    }
  end

  def emit(summary: base_summary, logs: [], service_name: self.service_name)
    described_class.emit_for_run(service_name:, summary:, logs:, finished_at:)
  end

  def rows
    OutboxEntry.where(record_kind: "sync_run")
  end

  it "enqueues one sync_run row for a successful service run" do
    emit(logs: [{ "service" => "Asana:work", "items_synced" => 3, "touched_collection_ids" => [7, 7, 9] }])

    expect(rows.length).to eq(1)
    row = rows.first
    expect(row.service_type).to eq("asana")
    expect(row.service_instance).to eq("asana:work")
    expect(row.observed_at).to eq(finished_at)
    expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:work:sync-run-20261005T100000Z-asana")
    expect(row.payload).to match(
      hash_including(
        "contract_version" => 1,
        "sync_run_id" => "sync-run-20261005T100000Z-asana",
        "service_type" => "asana",
        "service_instance" => "asana:work",
        "started_at" => "2026-10-05T10:00:00.000000Z",
        "finished_at" => "2026-10-05T10:05:00.000000Z",
        "last_attempted_at" => "2026-10-05T10:00:00.000000Z",
        "last_successful_at" => "2026-10-05T10:00:00.000000Z",
        "status" => "success",
        "items_synced" => 3,
        "touched_collection_ids" => [7, 9],
        "error" => nil
      )
    )
  end

  it "is idempotent for the same service run" do
    2.times { emit }

    expect(rows.length).to eq(1)
  end

  it "builds the service identity the same way item rows do for a default instance" do
    emit(service_name: "GoogleTasks")

    row = rows.first
    expect(row.service_type).to eq("google_tasks")
    expect(row.service_instance).to eq("google_tasks")
    expect(row.idempotency_key).to eq("tb:v1:sync_run:google_tasks:sync-run-20261005T100000Z-google_tasks")
  end

  it "publishes nothing for skipped or idle services" do
    emit(summary: base_summary.merge(status: "skipped"))
    emit(summary: base_summary.merge(status: "idle"))

    expect(rows).to be_empty
  end

  it "publishes nothing when the run has no attempt timestamp" do
    emit(summary: base_summary.merge(last_attempted: nil))

    expect(rows).to be_empty
  end

  describe "failed runs" do
    let(:base_summary) do
      super().merge(
        status: "failed",
        last_successful: nil,
        last_failed: "2026-10-05T10:04:00.000000Z",
        detail: "1 items processed — ProviderError: 401 unauthorized"
      )
    end

    it "carries the error provenance without a success timestamp" do
      emit(logs: [{ "service" => "Asana:work", "status" => "failed",
                    "error_class" => "ProviderError", "error_message" => "401 unauthorized" }])

      payload = rows.first.payload
      expect(payload["status"]).to eq("failed")
      expect(payload["last_successful_at"]).to be_nil
      expect(payload["last_failed_at"]).to eq("2026-10-05T10:04:00.000000Z")
      expect(payload["error"]).to eq(
        "class" => "ProviderError",
        "message" => "401 unauthorized",
        "retryable" => true
      )
    end

    it "falls back to operational detail when no structured error was logged" do
      emit(logs: [])

      expect(rows.first.payload["error"]).to match(
        hash_including("class" => "ProviderError", "message" => "1 items processed — ProviderError: 401 unauthorized")
      )
    end

    it "truncates long operational detail" do
      emit(summary: base_summary.merge(detail: "x" * 5_000), logs: [])

      expect(rows.first.payload.dig("error", "message").length).to eq(1_000)
    end
  end
end
