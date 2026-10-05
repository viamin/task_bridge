# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::WebPublisher::Response do
  def http(status, body = nil)
    described_class.from_http(status, body)
  end

  def results_response(results)
    http(200, { results: }.to_json)
  end

  it "reduces a 200 with per-row results to row_results" do
    response = results_response([{ idempotency_key: "k1", status: "accepted" }])

    expect(response.outcome).to eq(:row_results)
    expect(response.row_results).to eq([{ "idempotency_key" => "k1", "status" => "accepted" }])
  end

  it "treats an unreconcilable 200 as retryable so no row is assumed delivered" do
    expect(http(200, { accepted: 1 }.to_json).outcome).to eq(:retryable)
    expect(http(200, "not json").outcome).to eq(:retryable)
    expect(http(200, nil).outcome).to eq(:retryable)
  end

  it "classifies transient statuses and network errors as retryable" do
    expect(http(413).outcome).to eq(:retryable)
    expect(http(429).outcome).to eq(:retryable)
    expect(http(500).outcome).to eq(:retryable)
    expect(http(503).outcome).to eq(:retryable)
    expect(described_class.failure("Net::OpenTimeout", "timed out").outcome).to eq(:retryable)
  end

  it "classifies contract and authentication failures as terminal" do
    expect(http(400).outcome).to eq(:terminal)
    expect(http(401).outcome).to eq(:terminal)
    expect(http(409).outcome).to eq(:terminal)
    expect(http(422).outcome).to eq(:terminal)
    expect(http(302).outcome).to eq(:terminal)
    expect(http(404).outcome).to eq(:terminal)
  end

  it "exposes a stable error code for each failure shape" do
    expect(http(401).error_code).to eq("http_401")
    expect(described_class.failure("Net::OpenTimeout", "timed out").error_code).to eq("Net::OpenTimeout")
  end

  it "prefers the server's short error message and truncates it" do
    long = "x" * 500
    response = http(422, { error: { message: long } }.to_json)

    expect(response.summary_message.length).to eq(300)
    expect(response.summary_message).to start_with("x" * 290)
    expect(http(500, { message: "upstream down" }.to_json).summary_message).to eq("upstream down")
    expect(http(503).summary_message).to eq("HTTP 503")
    expect(described_class.failure("Net::OpenTimeout", "boom").summary_message).to eq("boom")
  end
end
