# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunEmitter do
  let(:started_at) { Time.zone.parse("2026-10-05T19:20:00Z") }
  let(:finished_at) { Time.zone.parse("2026-10-05T19:21:05Z") }
  let(:logs) do
    [{
      "service" => "Asana",
      "status" => "success",
      "last_attempted" => started_at.utc.iso8601(6),
      "last_successful" => started_at.utc.iso8601(6),
      "items_synced" => 12,
      "touched_collection_ids" => [84, 91]
    }]
  end
  let(:summary) do
    {
      service: "Asana",
      status: "success",
      items_synced: 12,
      last_attempted: started_at.utc.iso8601(6),
      last_successful: started_at.utc.iso8601(6),
      last_failed: nil,
      detail: "12 items processed"
    }
  end

  def emit(service_name: "Asana", summary: self.summary, logs: self.logs)
    described_class.emit_for_service(service_name, summary:, logs:, finished_at:)
  end

  describe ".emit_for_service" do
    it "enqueues one RDR #215 sync-run summary for a successful run" do
      emit

      row = OutboxEntry.find_by!(record_kind: "sync_run")
      expect(row).to have_attributes(
        service_type: "asana",
        service_instance: "asana",
        observed_at: started_at,
        status: "pending"
      )
      expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:sync-run-20261005T192000Z-asana")
      expect(row.payload).to include(
        "contract_version" => 1,
        "sync_run_id" => "sync-run-20261005T192000Z-asana",
        "service_type" => "asana",
        "service_instance" => "asana",
        "started_at" => "2026-10-05T19:20:00.000000Z",
        "finished_at" => "2026-10-05T19:21:05.000000Z",
        "last_attempted_at" => "2026-10-05T19:20:00.000000Z",
        "last_successful_at" => "2026-10-05T19:20:00.000000Z",
        "status" => "success",
        "items_synced" => 12,
        "touched_collection_ids" => [84, 91],
        "detail" => "12 items processed"
      )
      expect(row.payload["last_failed_at"]).to be_nil
      expect(row.payload["error"]).to be_nil
    end

    it "carries a structured, retryable error for failed runs" do
      failed_logs = [{
        "service" => "Github",
        "status" => "failed",
        "last_attempted" => started_at.utc.iso8601(6),
        "last_failed" => finished_at.utc.iso8601(6),
        "items_synced" => 0,
        "error_class" => "ProviderError",
        "error_message" => "401 unauthorized"
      }]
      failed_summary = {
        service: "Github",
        status: "failed",
        items_synced: 0,
        last_attempted: started_at.utc.iso8601(6),
        last_successful: nil,
        last_failed: finished_at.utc.iso8601(6),
        detail: "ProviderError: 401 unauthorized"
      }

      emit(service_name: "Github", summary: failed_summary, logs: failed_logs)

      payload = OutboxEntry.find_by!(record_kind: "sync_run").payload
      expect(payload).to include(
        "status" => "failed",
        "last_successful_at" => nil,
        "last_failed_at" => "2026-10-05T19:21:05.000000Z"
      )
      expect(payload["error"]).to eq(
        "class" => "ProviderError",
        "message" => "401 unauthorized",
        "retryable" => true
      )
    end

    it "qualifies service_instance for instance-scoped services" do
      emit(service_name: "Asana:work")

      row = OutboxEntry.find_by!(record_kind: "sync_run")
      expect(row.service_instance).to eq("asana:work")
      expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:work:sync-run-20261005T192000Z-asana")
      expect(row.payload["service_instance"]).to eq("asana:work")
    end

    it "publishes nothing for skipped or idle runs" do
      aggregate_failures do
        emit(summary: summary.merge(status: "skipped"))
        emit(summary: summary.merge(status: "idle"), logs: [])
        expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
      end
    end

    it "is idempotent for the same run" do
      first_row = emit
      second_row = emit

      expect(second_row.id).to eq(first_row.id)
      expect(OutboxEntry.where(record_kind: "sync_run").count).to eq(1)
    end

    it "isolates outbox write failures instead of raising" do
      allow(OutboxEntry).to receive(:enqueue).and_raise(ActiveRecord::ActiveRecordError, "database is locked")

      expect do
        expect(emit).to be_nil
      end.to output(/dropping sync run for sync-run-20261005T192000Z-asana/).to_stderr
    end

    it "truncates long operational detail" do
      emit(summary: summary.merge(detail: "x" * 500))

      expect(OutboxEntry.find_by!(record_kind: "sync_run").payload["detail"].length).to eq(300)
    end
  end
end
