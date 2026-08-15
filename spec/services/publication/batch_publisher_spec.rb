# frozen_string_literal: true

require "rails_helper"

RSpec.describe Publication::BatchPublisher do
  let(:endpoint)  { "https://taskbridge-web.example.com/api/task_bridge/v1/ingestion/batches" }
  let(:api_key)   { "test-api-key" }
  let(:publisher) { described_class.new(endpoint:, api_key:) }

  def make_entry(key:, kind: "item", payload: nil)
    payload ||= { contract_version: 1, idempotency_key: key, source: {} }.to_json
    instance_double(
      PublicationOutboxEntry,
      idempotency_key: key,
      record_kind: kind,
      parsed_payload: JSON.parse(payload, symbolize_names: true)
    )
  end

  def stub_http(status:, body:)
    response = instance_double(
      HTTParty::Response,
      code: status,
      body: body.is_a?(Hash) ? body.to_json : body
    )
    allow(HTTParty).to receive(:post).and_return(response)
    response
  end

  let(:entry) { make_entry(key: "tb:v1:item:asana:default:1:snapshot:2026-08-14T19:00:00.000000Z") }

  describe "#publish" do
    it "raises ArgumentError when entries array is empty" do
      expect { publisher.publish([]) }.to raise_error(ArgumentError, /must not be empty/)
    end

    context "when the server returns 200 with accepted results" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "some-batch-id",
            contract_version: 1,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{ record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" }]
          }
        )
      end

      it "returns one EntryResult per submitted entry" do
        expect(publisher.publish([entry]).length).to eq(1)
      end

      it "marks the result as accepted" do
        expect(publisher.publish([entry]).first).to be_accepted
      end

      it "attaches the entry to the result" do
        expect(publisher.publish([entry]).first.entry).to eq(entry)
      end
    end

    context "when the server returns 200 with a replayed result" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 0, replayed: 1, rejected: 0,
            results: [{ idempotency_key: entry.idempotency_key, status: "replayed" }]
          }
        )
      end

      it "marks the result as replayed" do
        expect(publisher.publish([entry]).first).to be_replayed
      end
    end

    context "when the server returns 200 with a rejected row" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 0, replayed: 0, rejected: 1,
            results: [{
              idempotency_key: entry.idempotency_key,
              status: "rejected",
              retryable: false,
              error_code: "validation_error",
              message: "source.service_instance is required"
            }]
          }
        )
      end

      it "marks the result as rejected with error details" do
        result = publisher.publish([entry]).first
        expect(result).to be_rejected
        expect(result.error_code).to eq("validation_error")
        expect(result.message).to include("service_instance")
      end
    end

    context "when the server returns 401" do
      before { stub_http(status: 401, body: "Unauthorized") }

      it "raises a non-retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /authentication/
        ) { |e| expect(e.retryable).to be false }
      end
    end

    context "when the server returns 429" do
      before { stub_http(status: 429, body: "Rate limited") }

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the server returns 500" do
      before { stub_http(status: 500, body: "Internal Server Error") }

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError
        ) { |e| expect(e.retryable).to be true }
      end
    end

    it "sends required contract headers to the endpoint" do
      stub_http(
        status: 200,
        body: {
          batch_id: "x", contract_version: 1,
          accepted: 1, replayed: 0, rejected: 0,
          results: [{ idempotency_key: entry.idempotency_key, status: "accepted" }]
        }
      )
      publisher.publish([entry])
      expect(HTTParty).to have_received(:post).with(
        endpoint,
        hash_including(
          headers: hash_including(
            "Authorization" => "Bearer #{api_key}",
            "X-TaskBridge-Contract-Version" => "1"
          )
        )
      )
    end

    context "when the response body is not valid JSON" do
      before { stub_http(status: 200, body: "not json") }

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when an entry has no matching result in the response" do
      before do
        stub_http(
          status: 200,
          body: { batch_id: "x", contract_version: 1, accepted: 0, replayed: 0, rejected: 0, results: [] }
        )
      end

      it "marks the entry as rejected with missing_result error code" do
        result = publisher.publish([entry]).first
        expect(result).to be_rejected
        expect(result.error_code).to eq("missing_result")
      end
    end
  end

  describe Publication::DeliveryError do
    it "exposes retryable" do
      err = described_class.new("oops", retryable: true)
      expect(err.retryable).to be true
    end

    it "is a StandardError" do
      expect(described_class.new("x", retryable: false)).to be_a(StandardError)
    end
  end
end
