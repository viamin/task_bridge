# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunEmitter do
  let(:started_at) { Time.zone.parse("2026-10-05T10:00:00Z") }
  let(:finished_at) { Time.zone.parse("2026-10-05T10:01:05Z") }
  let(:success_summary) do
    {
      "service" => "Asana:work",
      "status" => "success",
      "items_synced" => 12,
      "last_attempted" => "2026-10-05T10:00:00.000000Z",
      "last_successful" => "2026-10-05T10:01:05.000000Z",
      "last_failed" => nil,
      "detail" => "12 items processed"
    }
  end
  let(:success_logs) do
    [{
      "service" => "Asana:work",
      "status" => "success",
      "items_synced" => 12,
      "touched_collection_ids" => [84, 91, 84]
    }.stringify_keys]
  end

  def emit_for(summary:, service_logs:, service_name: "Asana:work")
    described_class.emit_for(
      service_name:,
      summary:,
      service_logs:,
      started_at:,
      finished_at:
    )
  end

  it "enqueues one sync_run row for a successful run" do
    entry = emit_for(summary: success_summary, service_logs: success_logs)

    expect(entry).to be_persisted
    expect(entry.record_kind).to eq("sync_run")
    expect(entry.service_type).to eq("asana")
    expect(entry.service_instance).to eq("asana:work")
    expect(entry.observed_at).to eq(finished_at)
    expect(entry.idempotency_key).to eq("tb:v1:sync_run:asana:work:sync-run-20261005T100000Z-asana_work")
    expect(entry.payload).to include(
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
      "detail" => "12 items processed",
      "error" => nil
    )
  end

  it "carries the run's error on failed runs" do
    failed_summary = success_summary.merge(
      "status" => "failed",
      "last_successful" => nil,
      "last_failed" => "2026-10-05T10:01:05.000000Z"
    )
    failed_logs = [{
      "service" => "Asana:work",
      "status" => "failed",
      "items_synced" => 0,
      "error_class" => "ProviderError",
      "error_message" => "401 unauthorized"
    }.stringify_keys]

    entry = emit_for(summary: failed_summary, service_logs: failed_logs)

    expect(entry.payload).to include(
      "status" => "failed",
      "last_successful_at" => nil,
      "last_failed_at" => "2026-10-05T10:01:05.000000Z"
    )
    expect(entry.payload["error"]).to include(
      "class" => "ProviderError",
      "message" => "401 unauthorized",
      "retryable" => true
    )
  end

  it "defaults a missing error class to ProviderError" do
    failed_logs = [{ "service" => "Asana", "status" => "failed", "error_message" => "boom" }.stringify_keys]
    failed_summary = success_summary.merge("status" => "failed")

    entry = emit_for(summary: failed_summary, service_logs: failed_logs, service_name: "Asana")

    expect(entry.payload["error"]).to include("class" => "ProviderError", "message" => "boom")
  end

  it "does not publish skipped or idle runs" do
    %w[skipped idle].each do |status|
      expect(emit_for(summary: success_summary.merge("status" => status), service_logs: [])).to be_nil
    end

    expect(OutboxEntry.where(record_kind: "sync_run")).to be_empty
  end

  it "is idempotent per run: re-emitting the same run reuses its row" do
    2.times { emit_for(summary: success_summary, service_logs: success_logs) }

    expect(OutboxEntry.where(record_kind: "sync_run").count).to eq(1)
  end

  it "isolates enqueue failures instead of raising into the sync flow" do
    allow(OutboxEntry).to receive(:enqueue).and_raise(ActiveRecord::ActiveRecordError, "simulated outbox failure")

    expect do
      emit_for(summary: success_summary, service_logs: success_logs)
    end.to output(/dropping sync run summary for Asana:work/).to_stderr
  end
end
