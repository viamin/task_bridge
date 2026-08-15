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

  def stub_http(status:, body:, echo_batch_id: true)
    allow(HTTParty).to receive(:post) do |_endpoint, opts|
      payload = body.is_a?(Hash) && echo_batch_id ? body.merge(batch_id: opts[:headers]["X-TaskBridge-Batch-Id"]) : body
      instance_double(
        HTTParty::Response,
        code: status,
        body: payload.is_a?(String) ? payload : payload.to_json
      )
    end
  end

  let(:entry) { make_entry(key: "tb:v1:item:asana:default:1:snapshot:2026-08-14T19:00:00.000000Z") }

  describe "#initialize" do
    it "raises ArgumentError when endpoint is blank" do
      expect { described_class.new(endpoint: "", api_key:) }.to raise_error(ArgumentError, /endpoint/)
    end

    it "raises ArgumentError when api_key is blank" do
      expect { described_class.new(endpoint:, api_key: "") }.to raise_error(ArgumentError, /api_key/)
    end

    it "raises ArgumentError when timeout is not a positive integer" do
      expect { described_class.new(endpoint:, api_key:, timeout: 0) }.to raise_error(ArgumentError, /timeout/)
      expect { described_class.new(endpoint:, api_key:, timeout: "30") }.to raise_error(ArgumentError, /timeout/)
    end

    it "raises ArgumentError when endpoint is not a parseable URI" do
      expect { described_class.new(endpoint: "not a uri", api_key:) }.to raise_error(ArgumentError, /valid http\(s\) URI/)
    end

    it "raises ArgumentError when endpoint lacks a scheme or host" do
      expect { described_class.new(endpoint: "taskbridge-web.example.com/api", api_key:) }
        .to raise_error(ArgumentError, /valid http\(s\) URI/)
      expect { described_class.new(endpoint: "https://", api_key:) }.to raise_error(ArgumentError, /valid http\(s\) URI/)
    end

    it "raises ArgumentError when endpoint uses a non-http scheme" do
      expect { described_class.new(endpoint: "ftp://taskbridge-web.example.com", api_key:) }
        .to raise_error(ArgumentError, /valid http\(s\) URI/)
    end
  end

  describe "#publish" do
    it "raises ArgumentError when entries array is empty" do
      expect { publisher.publish([]) }.to raise_error(ArgumentError, /must not be empty/)
    end

    it "raises ArgumentError when an entry has an unknown record_kind" do
      bogus = make_entry(key: "tb:v1:bogus:1", kind: "bogus")
      expect { publisher.publish([bogus]) }.to raise_error(ArgumentError, /unknown record_kind/)
    end

    it "does not send an HTTP request when an entry has an unknown record_kind" do
      allow(HTTParty).to receive(:post)
      bogus = make_entry(key: "tb:v1:bogus:1", kind: "bogus")
      expect { publisher.publish([bogus]) }.to raise_error(ArgumentError)
      expect(HTTParty).not_to have_received(:post)
    end

    it "raises ArgumentError when two entries share an idempotency_key" do
      duplicate = make_entry(key: entry.idempotency_key)
      expect { publisher.publish([entry, duplicate]) }.to raise_error(ArgumentError, /duplicate idempotency_key/)
    end

    it "does not send an HTTP request when entries share an idempotency_key" do
      allow(HTTParty).to receive(:post)
      duplicate = make_entry(key: entry.idempotency_key)
      expect { publisher.publish([entry, duplicate]) }.to raise_error(ArgumentError)
      expect(HTTParty).not_to have_received(:post)
    end

    context "when a stored payload carries a different contract_version" do
      let(:v2_entry) do
        make_entry(
          key: "tb:v1:item:asana:default:2:snapshot:2026-08-14T19:00:00.000000Z",
          payload: { contract_version: 2, idempotency_key: "tb:v1:item:asana:default:2:snapshot:2026-08-14T19:00:00.000000Z" }.to_json
        )
      end

      it "raises ArgumentError instead of silently sending a v2 row in a v1 batch" do
        expect { publisher.publish([v2_entry]) }.to raise_error(ArgumentError, /payload contract_version/)
      end

      it "does not send an HTTP request" do
        allow(HTTParty).to receive(:post)
        expect { publisher.publish([v2_entry]) }.to raise_error(ArgumentError)
        expect(HTTParty).not_to have_received(:post)
      end
    end

    it "raises ArgumentError when a stored payload omits contract_version" do
      bare = make_entry(
        key: "tb:v1:item:asana:default:3:snapshot:2026-08-14T19:00:00.000000Z",
        payload: { idempotency_key: "tb:v1:item:asana:default:3:snapshot:2026-08-14T19:00:00.000000Z" }.to_json
      )
      expect { publisher.publish([bare]) }.to raise_error(ArgumentError, /payload contract_version/)
    end

    context "when a stored payload carries a different idempotency_key than its outbox row" do
      let(:mismatched) do
        make_entry(
          key: "tb:v1:item:asana:default:6:snapshot:2026-08-14T19:00:00.000000Z",
          payload: {
            contract_version: 1,
            idempotency_key: "tb:v1:item:asana:default:different:snapshot:2026-08-14T19:00:00.000000Z"
          }.to_json
        )
      end

      it "raises ArgumentError because the row could never be reconciled from the response" do
        expect { publisher.publish([mismatched]) }.to raise_error(ArgumentError, /payload idempotency_key must match/)
      end

      it "does not send an HTTP request" do
        allow(HTTParty).to receive(:post)
        expect { publisher.publish([mismatched]) }.to raise_error(ArgumentError)
        expect(HTTParty).not_to have_received(:post)
      end
    end

    context "when a stored payload is corrupt" do
      it "raises ArgumentError naming the row instead of leaking a JSON error" do
        corrupt = make_entry(key: "tb:v1:item:asana:default:4:snapshot:2026-08-14T19:00:00.000000Z")
        allow(corrupt).to receive(:parsed_payload).and_raise(JSON::ParserError, "unexpected token")
        expect { publisher.publish([corrupt]) }.to raise_error(ArgumentError, /unparseable payload .*asana:default:4/)
      end

      it "raises ArgumentError when the payload parses to a non-object" do
        array_payload = make_entry(
          key: "tb:v1:item:asana:default:5:snapshot:2026-08-14T19:00:00.000000Z",
          payload: "[1, 2]"
        )
        expect { publisher.publish([array_payload]) }.to raise_error(ArgumentError, /must be a JSON object/)
      end

      it "does not send an HTTP request" do
        allow(HTTParty).to receive(:post)
        array_payload = make_entry(
          key: "tb:v1:item:asana:default:5:snapshot:2026-08-14T19:00:00.000000Z",
          payload: "[1, 2]"
        )
        expect { publisher.publish([array_payload]) }.to raise_error(ArgumentError)
        expect(HTTParty).not_to have_received(:post)
      end
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
        expect(result.retryable).to be false
        expect(result.error_code).to eq("validation_error")
        expect(result.message).to include("service_instance")
      end
    end

    context "when a result carries a non-boolean retryable value" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 0, replayed: 0, rejected: 1,
            results: [{
              idempotency_key: entry.idempotency_key,
              status: "rejected",
              retryable: "yes",
              error_code: "validation_error",
              message: "bad row"
            }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of trusting the value" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /retryable must be a boolean/
        ) { |e| expect(e.retryable).to be true }
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

    describe "remaining HTTP status to retryability mapping" do
      {
        400 => false,
        404 => false,
        409 => false,
        413 => true,
        422 => false,
        503 => true
      }.each do |code, retryable|
        it "maps #{code} to a #{retryable ? 'retryable' : 'non-retryable'} DeliveryError" do
          stub_http(status: code, body: "error")
          expect { publisher.publish([entry]) }.to raise_error(Publication::DeliveryError) do |e|
            expect(e.retryable).to be retryable
          end
        end
      end
    end

    context "when the connection is refused" do
      before { allow(HTTParty).to receive(:post).and_raise(Errno::ECONNREFUSED, "Connection refused") }

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /transport error/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the connection times out during write" do
      before { allow(HTTParty).to receive(:post).and_raise(Net::WriteTimeout) }

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /transport error/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the TLS handshake fails" do
      before { allow(HTTParty).to receive(:post).and_raise(OpenSSL::SSL::SSLError, "certificate verify failed") }

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /transport error/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the response echoes a different batch_id" do
      before do
        stub_http(
          status: 200,
          body: { batch_id: "a-different-batch-id", contract_version: 1, accepted: 0, replayed: 0, rejected: 0, results: [] },
          echo_batch_id: false
        )
      end

      it "raises a retryable DeliveryError instead of trusting the results" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /batch_id mismatch/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a 200 response body is not a JSON object" do
      before { stub_http(status: 200, body: '"ok"') }

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /expected a JSON object/
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

    it "sends the configured timeout with the request" do
      stub_http(
        status: 200,
        body: {
          batch_id: "x", contract_version: 1,
          accepted: 1, replayed: 0, rejected: 0,
          results: [{ idempotency_key: entry.idempotency_key, status: "accepted" }]
        }
      )
      described_class.new(endpoint:, api_key:, timeout: 5).publish([entry])
      expect(HTTParty).to have_received(:post).with(endpoint, hash_including(timeout: 5))
    end

    it "stamps every row in the batch with the same published_at" do
      second = make_entry(key: "tb:v1:item:asana:default:2:snapshot:2026-08-14T19:00:00.000000Z")
      captured = nil
      allow(HTTParty).to receive(:post) do |_endpoint, options|
        captured = options
        instance_double(
          HTTParty::Response,
          code: 200,
          body: {
            batch_id: options[:headers]["X-TaskBridge-Batch-Id"], contract_version: 1,
            accepted: 2, replayed: 0, rejected: 0,
            results: [entry, second].map { |e| { idempotency_key: e.idempotency_key, status: "accepted" } }
          }.to_json
        )
      end

      publisher.publish([entry, second])

      body = JSON.parse(captured[:body], symbolize_names: true)
      timestamps = body[:items].map { |item| item[:published_at] }
      expect(timestamps).to all(be_present)
      expect(timestamps.uniq.length).to eq(1)
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
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{ idempotency_key: "tb:v1:item:other:1", status: "accepted" }]
          }
        )
      end

      it "marks the entry as rejected with missing_result error code" do
        result = publisher.publish([entry]).first
        expect(result).to be_rejected
        expect(result.error_code).to eq("missing_result")
      end

      it "flags the row as retryable because delivery state is ambiguous" do
        result = publisher.publish([entry]).first
        expect(result.retryable).to be true
      end
    end

    context "when the response omits a result for a submitted row" do
      before do
        stub_http(
          status: 200,
          body: { batch_id: "x", contract_version: 1, accepted: 0, replayed: 0, rejected: 0, results: [] }
        )
      end

      it "raises a retryable DeliveryError instead of trusting the response" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /unreconcilable response/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the response returns more results than submitted rows" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 2, replayed: 0, rejected: 0,
            results: [
              { idempotency_key: entry.idempotency_key, status: "accepted" },
              { idempotency_key: "tb:v1:item:other:1", status: "accepted" }
            ]
          }
        )
      end

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /unreconcilable response/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a result carries an unknown status" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{ idempotency_key: entry.idempotency_key, status: "queued" }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of acting on the status" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /unknown result status/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the response echoes a different contract version" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 2,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{ idempotency_key: entry.idempotency_key, status: "accepted" }]
          }
        )
      end

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /contract_version mismatch/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a result carries a mismatched record_kind" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{ record_kind: "observation", idempotency_key: entry.idempotency_key, status: "accepted" }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of trusting the result" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /record_kind mismatch/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when results is not an array" do
      before do
        stub_http(
          status: 200,
          body: { batch_id: "x", contract_version: 1, accepted: 1, replayed: 0, rejected: 0, results: { "0" => "accepted" } }
        )
      end

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /results must be an array/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a results element is not an object" do
      before do
        stub_http(
          status: 200,
          body: { batch_id: "x", contract_version: 1, accepted: 1, replayed: 0, rejected: 0, results: ["accepted"] }
        )
      end

      it "raises a retryable DeliveryError instead of a TypeError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /results must be an array/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the response repeats an idempotency_key in results" do
      let(:second) { make_entry(key: "tb:v1:item:asana:default:2:snapshot:2026-08-14T19:00:00.000000Z") }

      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 2, replayed: 0, rejected: 0,
            results: [
              { idempotency_key: entry.idempotency_key, status: "accepted" },
              { idempotency_key: entry.idempotency_key, status: "accepted" }
            ]
          }
        )
      end

      it "raises a retryable DeliveryError instead of reconciling against the wrong row" do
        expect { publisher.publish([entry, second]) }.to raise_error(
          Publication::DeliveryError, /duplicate idempotency_key/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the count fields do not match the number of results" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 2, replayed: 0, rejected: 0,
            results: [{ idempotency_key: entry.idempotency_key, status: "accepted" }]
          }
        )
      end

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /unreconcilable response/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the count fields are missing" do
      before do
        stub_http(
          status: 200,
          body: { batch_id: "x", contract_version: 1, results: [{ idempotency_key: entry.idempotency_key, status: "accepted" }] }
        )
      end

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /unreconcilable response/
        ) { |e| expect(e.retryable).to be true }
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
