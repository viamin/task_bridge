# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::IsolatedWrite do
  def statement_invalid(message = "database is locked")
    ActiveRecord::StatementInvalid.new(message)
  end

  it "returns the block value when the write succeeds" do
    expect(described_class.call("observation for test_service:obs-1", retry_delays: []) { :result }).to eq(:result)
  end

  it "retries a transient failure and returns the block value once it succeeds" do
    attempts = 0
    result = described_class.call("observation for test_service:obs-1", retry_delays: [0, 0]) do
      attempts += 1
      raise statement_invalid if attempts < 3

      :recovered
    end

    expect(result).to eq(:recovered)
    expect(attempts).to eq(3)
  end

  it "warns while retrying a transient failure" do
    attempts = 0
    expect do
      described_class.call("mapping for github:issue-42", retry_delays: [0]) do
        attempts += 1
        raise statement_invalid("SQLite3::BusyException") if attempts < 2
      end
    end.to output(/retrying mapping for github:issue-42/).to_stderr
  end

  it "reports and swallows the failure once retries are exhausted" do
    attempts = 0
    result = nil
    expect do
      result = described_class.call("observation for test_service:obs-1", retry_delays: [0, 0]) do
        attempts += 1
        raise statement_invalid
      end
    end.not_to raise_error
    expect(result).to be_nil
    expect(attempts).to eq(3)
  end

  it "reports non-transient database failures without retrying" do
    attempts = 0
    result = described_class.call("mapping for github:issue-42", retry_delays: [0, 0]) do
      attempts += 1
      raise ActiveRecord::ActiveRecordError, "simulated outbox failure"
    end
    expect(result).to be_nil
    expect(attempts).to eq(1)
  end

  it "does not retry when the database itself is missing" do
    attempts = 0
    described_class.call("observation for test_service:obs-1", retry_delays: [0]) do
      attempts += 1
      raise ActiveRecord::NoDatabaseError, "test database missing"
    end
    expect(attempts).to eq(1)
  end

  it "warns with the error class when a write is dropped" do
    expect do
      described_class.call("observation for test_service:obs-1", retry_delays: []) do
        raise statement_invalid("SQLite3::BusyException")
      end
    end.to output(/dropping observation for test_service:obs-1.*SQLite3::BusyException/).to_stderr
  end
end
