# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunEmitter do
  include ActiveSupport::Testing::TimeHelpers

  let(:finished_at) { Time.zone.parse("2026-10-05T12:00:05Z") }
  let(:sync_run_id) { "sync-run-2026-10-05T10:00:00.000000Z" }
  let(:started_at) { "2026-10-05T10:00:00.000000Z" }
  let(:service) { instance_double("Asana::Service", service_name: "Asana:work") }
  let(:summary) do
    {
      service: "Asana:work",
      status: "success",
      items_synced: 3,
      last_attempted: started_at,
      last_successful: "2026-10-05T12:00:04.000000Z",
      last_failed: nil,
      detail: "3 items processed"
    }
  end

  def emit(logs: [])
    travel_to(finished_at) do
      described_class.emit_for_run(service:, summary:, logs:, sync_run_id:, started_at:)
    end
  end

  def sync_run_rows
    OutboxEntry.where(record_kind: "sync_run")
  end

  describe "a successful service run" do
    it "enqueues one sync-run summary row matching the RDR #215 schema" do
      emit(logs: [{ "touched_collection_ids" => [84, 91, 84] }])

      expect(sync_run_rows.length).to eq(1)
      row = sync_run_rows.sole
      expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:work:#{sync_run_id}")
      expect(row.service_type).to eq("asana")
      expect(row.service_instance).to eq("asana:work")
      expect(row.observed_at).to eq(finished_at)
      expect(row.payload).to include(
        "contract_version" => 1,
        "sync_run_id" => sync_run_id,
        "service_type" => "asana",
        "service_instance" => "asana:work",
        "started_at" => "2026-10-05T10:00:00.000000Z",
        "finished_at" => "2026-10-05T12:00:05.000000Z",
        "last_attempted_at" => "2026-10-05T10:00:00.000000Z",
        "last_successful_at" => "2026-10-05T12:00:04.000000Z",
        "last_failed_at" => nil,
        "status" => "success",
        "items_synced" => 3,
        "touched_collection_ids" => [84, 91],
        "detail" => "3 items processed",
        "error" => nil
      )
    end

    it "is idempotent per run" do
      2.times { emit }

      expect(sync_run_rows.length).to eq(1)
    end
  end

  describe "a failed service run" do
    let(:summary) do
      {
        service: "Asana:work",
        status: "failed",
        items_synced: 0,
        last_attempted: started_at,
        last_successful: nil,
        last_failed: "2026-10-05T12:00:04.000000Z",
        detail: "ProviderError: 401 unauthorized (2026-10-05T12:00:04.000000Z)"
      }
    end
    let(:logs) do
      [{
        "service" => "Asana:work",
        "status" => "failed",
        "error_class" => "ProviderError",
        "error_message" => "401 unauthorized",
        "items_synced" => 0
      }]
    end

    it "publishes the structured error from the failed run's log entry" do
      emit(logs:)

      expect(sync_run_rows.sole.payload).to include(
        "status" => "failed",
        "items_synced" => 0,
        "last_failed_at" => "2026-10-05T12:00:04.000000Z",
        "error" => { "class" => "ProviderError", "message" => "401 unauthorized", "retryable" => true }
      )
    end

    it "marks authentication failures as not retryable" do
      allow(service).to receive(:authorized).and_return(false)

      emit(logs:)

      expect(sync_run_rows.sole.payload.dig("error", "retryable")).to be(false)
    end
  end

  describe "runs that must not publish a summary" do
    it "skips skipped and idle runs" do
      ["skipped", "idle", nil].each do |status|
        travel_to(finished_at) do
          described_class.emit_for_run(
            service:, summary: summary.merge(status:), logs: [], sync_run_id:, started_at:
          )
        end
      end

      expect(sync_run_rows).to be_empty
    end

    it "skips runs without a sync run identifier" do
      travel_to(finished_at) do
        described_class.emit_for_run(service:, summary:, logs: [], sync_run_id: nil, started_at:)
      end

      expect(sync_run_rows).to be_empty
    end
  end

  describe "service identity" do
    it "falls back to friendly_name for services without service_name" do
      service = instance_double("Passing::Service", friendly_name: "Passing")

      travel_to(finished_at) do
        described_class.emit_for_run(service:, summary:, logs: [], sync_run_id:, started_at:)
      end

      row = sync_run_rows.sole
      expect(row.service_type).to eq("passing")
      expect(row.service_instance).to eq("passing")
      expect(row.idempotency_key).to eq("tb:v1:sync_run:passing:#{sync_run_id}")
    end
  end

  describe "text bounds" do
    it "truncates oversized detail to the text limit" do
      travel_to(finished_at) do
        described_class.emit_for_run(
          service:, summary: summary.merge(detail: "x" * 500), logs: [], sync_run_id:, started_at:
        )
      end

      expected_detail = "#{'x' * (described_class::TEXT_LIMIT - 3)}..."
      expect(sync_run_rows.sole.payload["detail"]).to eq(expected_detail)
    end
  end
end
