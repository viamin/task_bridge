# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunEmitter do
  let(:started_at) { Time.zone.parse("2026-08-14T19:20:00Z") }
  let(:finished_at) { Time.zone.parse("2026-08-14T19:21:05Z") }

  def emit(summary, logs: [], service_name: "Asana")
    described_class.emit_for_run(
      summary,
      service_name:,
      started_at:,
      logs:,
      finished_at:
    )
  end

  def success_summary
    {
      service: "Asana",
      status: "success",
      items_synced: 12,
      last_attempted: "2026-08-14T19:20:00.000000Z",
      last_successful: "2026-08-14T19:21:05.000000Z",
      last_failed: nil,
      detail: "12 items processed"
    }
  end

  it "enqueues one sync_run row mapped to the contract's field names" do
    entry = emit(success_summary, logs: [{ "touched_collection_ids" => [84, 91, 84] }])

    expect(entry.record_kind).to eq("sync_run")
    expect(entry.service_type).to eq("asana")
    expect(entry.service_instance).to eq("asana")
    expect(entry.payload).to include(
      "contract_version" => 1,
      "sync_run_id" => "sync-run-20260814T192000Z-asana",
      "service_type" => "asana",
      "service_instance" => "asana",
      "started_at" => "2026-08-14T19:20:00.000000Z",
      "finished_at" => "2026-08-14T19:21:05.000000Z",
      "last_attempted_at" => "2026-08-14T19:20:00.000000Z",
      "last_successful_at" => "2026-08-14T19:21:05.000000Z",
      "last_failed_at" => nil,
      "status" => "success",
      "items_synced" => 12,
      "touched_collection_ids" => [84, 91],
      "detail" => "12 items processed",
      "error" => nil
    )
    expect(entry.idempotency_key).to eq("tb:v1:sync_run:asana:sync-run-20260814T192000Z-asana")
  end

  it "carries the service instance in the identity when the service name qualifies one" do
    entry = emit(success_summary, service_name: "Asana:work")

    # Matches Outbox::SourceIdentity's convention for instance-qualified
    # services: the identifier absorbs the instance segment.
    expect(entry.service_instance).to eq("asana_work:work")
    expect(entry.payload["service_instance"]).to eq("asana_work:work")
  end

  it "includes a retryable error only for failed runs" do
    logs = [
      {
        "service" => "Github",
        "status" => "failed",
        "error_class" => "ProviderError",
        "error_message" => "401 unauthorized"
      }.stringify_keys
    ]
    summary = {
      service: "Github",
      status: "failed",
      items_synced: 0,
      last_attempted: "2026-08-14T19:30:00.000000Z",
      last_successful: nil,
      last_failed: "2026-08-14T19:30:02.000000Z",
      detail: "ProviderError: 401 unauthorized"
    }

    entry = emit(summary, logs:, service_name: "Github")

    expect(entry.payload["status"]).to eq("failed")
    expect(entry.payload["error"]).to eq(
      "class" => "ProviderError",
      "message" => "401 unauthorized",
      "retryable" => true
    )
    expect(entry.payload["last_failed_at"]).to eq("2026-08-14T19:30:02.000000Z")
  end

  it "falls back to a truncated detail and default error class when logs lack error fields" do
    summary = {
      service: "Asana",
      status: "failed",
      items_synced: 0,
      last_attempted: "2026-08-14T19:30:00.000000Z",
      last_failed: "2026-08-14T19:30:02.000000Z",
      detail: "Failure recorded (2026-08-14T19:30:02.000000Z)"
    }

    entry = emit(summary)

    expect(entry.payload["error"]).to include("class" => "ProviderError", "retryable" => true)
    expect(entry.payload["detail"]).to eq("Failure recorded (2026-08-14T19:30:02.000000Z)")
  end

  it "publishes nothing for skipped or idle services" do
    [{ status: "skipped" }, { status: "idle" }, { status: nil }].each do |overrides|
      expect(emit(success_summary.merge(overrides))).to be_nil
    end

    expect(OutboxEntry.count).to eq(0)
  end

  it "is idempotent for the same run" do
    2.times { emit(success_summary) }

    expect(OutboxEntry.where(record_kind: "sync_run").count).to eq(1)
  end

  it "writes no rows in --pretend mode" do
    Thread.current[:global_options] = { pretend: true }

    expect(emit(success_summary)).to be_nil
    expect(OutboxEntry.count).to eq(0)
  end

  it "isolates write failures instead of raising into the sync flow" do
    allow(OutboxEntry).to receive(:enqueue).and_raise(ActiveRecord::StatementInvalid, "locked")

    expect { emit(success_summary) }.not_to raise_error
  end
end
