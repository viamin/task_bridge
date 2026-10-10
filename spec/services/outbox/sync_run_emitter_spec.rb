# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunEmitter do
  let(:started_at) { Time.zone.parse("2026-10-05T19:20:00Z") }
  let(:finished_at) { Time.zone.parse("2026-10-05T19:21:05Z") }
  let(:summary) do
    {
      service: "Asana",
      status: "success",
      items_synced: 12,
      last_attempted: "2026-10-05T19:20:00.000000Z",
      last_successful: "2026-10-05T19:21:05.000000Z",
      last_failed: nil,
      detail: "12 items processed"
    }
  end

  before { Thread.current[:global_options] = { pretend: false } }

  def emit_with(summary_overrides = {}, emit_overrides = {})
    described_class.emit_for_run(
      summary: summary.merge(summary_overrides),
      started_at:,
      finished_at:,
      **emit_overrides
    )
  end

  def sync_run_rows
    OutboxEntry.where(record_kind: "sync_run")
  end

  describe "a successful run" do
    it "enqueues a pending sync_run row with the RDR #215 payload shape" do
      row = emit_with({}, touched_collection_ids: [84, 91, 84])

      expect(row).to be_pending
      expect(row.service_type).to eq("asana")
      expect(row.service_instance).to eq("asana")
      expect(row.observed_at).to eq(finished_at)
      expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:sync-run-20261005T192000Z-asana")
      expect(row.payload).to include(
        "contract_version" => 1,
        "sync_run_id" => "sync-run-20261005T192000Z-asana",
        "service_type" => "asana",
        "service_instance" => "asana",
        "started_at" => "2026-10-05T19:20:00.000000Z",
        "finished_at" => "2026-10-05T19:21:05.000000Z",
        "last_attempted_at" => "2026-10-05T19:20:00.000000Z",
        "last_successful_at" => "2026-10-05T19:21:05.000000Z",
        "last_failed_at" => nil,
        "status" => "success",
        "items_synced" => 12,
        "touched_collection_ids" => [84, 91],
        "detail" => "12 items processed"
      )
      expect(row.payload).not_to have_key("error")
    end

    it "does not duplicate the row when the same run is emitted twice" do
      first_row = emit_with
      second_row = emit_with

      expect(second_row.id).to eq(first_row.id)
      expect(sync_run_rows.count).to eq(1)
    end
  end

  describe "a failed run" do
    it "carries the structured failure with the schedule's retry policy" do
      row = emit_with(
        { status: "failed", last_successful: nil, last_failed: "2026-10-05T19:21:05.000000Z", detail: "ProviderError: 401 unauthorized" },
        error: { "class" => "ProviderError", "message" => "401 unauthorized" }
      )

      expect(row.payload["status"]).to eq("failed")
      expect(row.payload["error"]).to eq("class" => "ProviderError", "message" => "401 unauthorized", "retryable" => true)
    end

    it "keeps error valid only with a non-success status" do
      row = emit_with({}, error: { "class" => "ProviderError", "message" => "401 unauthorized" })

      expect(row.payload["status"]).to eq("success")
      expect(row.payload).not_to have_key("error")
    end
  end

  describe "statuses that must not publish" do
    %w[skipped idle partial].each do |status|
      it "emits nothing for a #{status} run" do
        expect(emit_with(status:)).to be_nil
        expect(sync_run_rows.count).to eq(0)
      end
    end
  end

  describe "service instances" do
    it "distinguishes instance-qualified services like SourceIdentity does" do
      row = emit_with({ service: "Asana:work" })

      expect(row.service_type).to eq("asana")
      expect(row.service_instance).to eq("asana:work")
      expect(row.idempotency_key).to eq("tb:v1:sync_run:asana:work:sync-run-20261005T192000Z-asana_work")
    end
  end

  describe "sanitized operational text" do
    it "bounds detail and error message length" do
      long_detail = ("x" * 500)
      row = emit_with(
        { status: "failed", detail: long_detail },
        error: { "class" => "ProviderError", "message" => long_detail }
      )

      expect(row.payload["detail"].length).to eq(described_class::TEXT_LIMIT)
      expect(row.payload["error"]["message"].length).to eq(described_class::TEXT_LIMIT)
    end
  end

  describe "outbox write failures" do
    it "does not raise and reports the dropped summary" do
      allow(OutboxEntry).to receive(:enqueue).and_raise(ActiveRecord::ActiveRecordError, "simulated outbox failure")

      expect do
        expect do
          emit_with
        end.not_to raise_error
      end.to output(/dropping sync run summary for Asana/).to_stderr
    end
  end
end
