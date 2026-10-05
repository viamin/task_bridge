# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::WebPublisher::Client do
  let(:config) do
    Outbox::WebPublisher::Config.resolve(
      "enabled" => true,
      "base_url" => "https://web.example.com/tb",
      "api_key" => "secret",
      "timeout_seconds" => 7
    )
  end
  let(:transport) { instance_double(described_class::HttpTransport) }
  let(:client) { described_class.new(config, transport:) }
  let(:batch) { Outbox::WebPublisher::Batch.new([entry], now: Time.current) }
  let(:entry) do
    OutboxEntry.create!(
      idempotency_key: "tb:v1:obs:test_service:obs-1:snapshot_seen:2026-10-05T10:00:00.000000Z",
      record_kind: "observation", event_type: "snapshot_seen",
      service_type: "test_service", observed_at: Time.current,
      payload: { contract_version: 1 }
    )
  end

  it "posts the batch body with auth and transport headers plus the configured timeout" do
    allow(transport).to receive(:post).and_return(described_class::Raw.new(200, { results: [] }.to_json))

    client.post_batch(batch)

    expect(transport).to have_received(:post).with(
      batch.body_json,
      hash_including(
        timeout: 7,
        headers: hash_including(
          "Authorization" => "Bearer secret",
          "X-TaskBridge-Contract-Version" => "1",
          "X-TaskBridge-Batch-Id" => batch.body.dig(:batch, :batch_id)
        )
      )
    )
  end

  it "reduces HTTP statuses to responses" do
    allow(transport).to receive(:post).and_return(described_class::Raw.new(401, '{"error": "nope"}'))

    response = client.post_batch(batch)

    expect(response.outcome).to eq(:terminal)
    expect(response.error_code).to eq("http_401")
  end

  it "reduces network errors to retryable responses instead of raising" do
    allow(transport).to receive(:post).and_raise(Net::OpenTimeout, "connection open timed out")

    response = client.post_batch(batch)

    expect(response.outcome).to eq(:retryable)
    expect(response.error_code).to eq("Net::OpenTimeout")
    expect(response.summary_message).to eq("connection open timed out")
  end

  it "reduces errno failures Net::HTTP re-raises for POST to retryable responses" do
    [Errno::ECONNABORTED, Errno::EPIPE, Errno::ETIMEDOUT].each do |error_class|
      allow(transport).to receive(:post).and_raise(error_class, "transport failed")

      response = client.post_batch(batch)

      expect(response.outcome).to eq(:retryable)
      expect(response.error_code).to eq(error_class.name)
    end
  end

  describe "the default HTTP transport" do
    let(:http) { instance_double(Net::HTTP) }
    let(:raw_response) { instance_double(Net::HTTPResponse, code: "200", body: { results: [] }.to_json) }
    let(:captured_requests) { [] }
    let(:response) { described_class.new(config).post_batch(batch) }

    before do
      allow(Net::HTTP).to receive(:new).with("web.example.com", 443).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:write_timeout=)
      allow(http).to receive(:request) { |received|
        captured_requests << received
        raw_response
      }
    end

    it "posts to the ingestion endpoint under any base URL path prefix" do
      response

      expect(captured_requests.first.path).to eq("/tb/api/task_bridge/v1/ingestion/batches")
    end

    it "enables TLS with the configured timeouts and carries the batch body" do
      response

      expect(http).to have_received(:use_ssl=).with(true)
      expect(http).to have_received(:open_timeout=).with(7)
      expect(http).to have_received(:read_timeout=).with(7)
      expect(captured_requests.first.body).to eq(batch.body_json)
    end

    it "maps the raw HTTP response to a reduced response" do
      expect(response.outcome).to eq(:row_results)
    end
  end
end
