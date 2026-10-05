# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::WebPublisher::Reconciler do
  let(:now) { Time.zone.parse("2026-10-05T12:00:00Z") }
  let(:entries) { [accepted_entry, replayed_entry, retryable_entry, terminal_entry] }
  let(:accepted_entry) { create_entry("key-accepted") }
  let(:replayed_entry) { create_entry("key-replayed") }
  let(:retryable_entry) { create_entry("key-retryable") }
  let(:terminal_entry) { create_entry("key-terminal") }

  def create_entry(key)
    OutboxEntry.create!(
      idempotency_key: key,
      record_kind: "observation",
      event_type: "snapshot_seen",
      service_type: "test_service",
      service_instance: "test_service",
      external_id: key,
      observed_at: now,
      payload: { contract_version: 1 }
    )
  end

  def result(key, status, **fields)
    { "idempotency_key" => key, "status" => status }.merge(fields.stringify_keys)
  end

  it "marks accepted and replayed rows delivered" do
    described_class.apply(
      entries: [accepted_entry, replayed_entry],
      results: [result("key-accepted", "accepted"), result("key-replayed", "replayed")],
      now:
    )

    expect(accepted_entry.reload).to be_delivered
    expect(replayed_entry.reload).to be_delivered
    expect(accepted_entry.published_at).to eq(now)
  end

  it "schedules retryable rejections for a later attempt with the server's reason" do
    described_class.apply(
      entries: [retryable_entry],
      results: [result("key-retryable", "rejected", "retryable" => true,
                                                    "error_code" => "temporarily_unavailable", "message" => "try again")],
      now:
    )

    row = retryable_entry.reload
    expect(row).to be_pending
    expect(row.attempts).to eq(1)
    expect(row.next_retry_at).to be > now
    expect(row.error_class).to eq("temporarily_unavailable")
    expect(row.error_message).to eq("try again")
  end

  it "moves terminal rejections to failed for operator review" do
    described_class.apply(
      entries: [terminal_entry],
      results: [result("key-terminal", "rejected", "retryable" => false,
                                                   "error_code" => "validation_error", "message" => "source.service_instance is required")],
      now:
    )

    row = terminal_entry.reload
    expect(row).to be_failed
    expect(row.attempts).to eq(1)
    expect(row.next_retry_at).to be_nil
    expect(row.error_class).to eq("validation_error")
  end

  it "treats a missing or unrecognized result entry as an undelivered retryable row" do
    counts = described_class.apply(
      entries: [accepted_entry, retryable_entry],
      results: [result("key-accepted", "accepted"), result("key-retryable", "mystery")],
      now:
    )

    expect(counts).to eq(delivered: 1, retryable: 1, failed: 0)
    expect(accepted_entry.reload).to be_delivered
    row = retryable_entry.reload
    expect(row).to be_pending
    expect(row.next_retry_at).to be > now
  end

  it "treats malformed result entries as missing without raising" do
    counts = described_class.apply(
      entries: [accepted_entry, retryable_entry],
      results: [nil, 42, result("key-accepted", "accepted")],
      now:
    )

    expect(counts).to eq(delivered: 1, retryable: 1, failed: 0)
    expect(accepted_entry.reload).to be_delivered
    expect(retryable_entry.reload).to be_pending
    expect(retryable_entry.error_class).to eq("missing_result")
  end

  it "reports partial success counts" do
    counts = described_class.apply(
      entries:,
      results: [
        result("key-accepted", "accepted"),
        result("key-replayed", "replayed"),
        result("key-retryable", "rejected", "retryable" => true),
        result("key-terminal", "rejected", "retryable" => false)
      ],
      now:
    )

    expect(counts).to eq(delivered: 2, retryable: 1, failed: 1)
  end
end
