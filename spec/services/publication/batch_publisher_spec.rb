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
        code: status.to_s,
        body: payload.is_a?(String) ? payload : payload.to_json
      )
    end
  end

  # Stubs a successful per-row response for rows and returns a hash the stub
  # fills with the captured request options, so tests can assert on the sent
  # body and headers.
  def stub_success_and_capture_request(rows)
    captured = {}
    allow(HTTParty).to receive(:post) do |_endpoint, options|
      captured[:request] = options
      instance_double(
        HTTParty::Response,
        code: "200",
        body: {
          batch_id: options[:headers]["X-TaskBridge-Batch-Id"], contract_version: 1,
          accepted: rows.length, replayed: 0, rejected: 0,
          results: rows.map { |row| { record_kind: row.record_kind, idempotency_key: row.idempotency_key, status: "accepted" } }
        }.to_json
      )
    end
    captured
  end

  # A payload nested exactly at the JSON parse limit (99 levels): it parses
  # and standalone-generates fine, but exceeds the generation limit once the
  # batch envelope wraps it two levels deeper.
  def deep_nested_payload(key)
    opening = %({"v":) * 98
    closing = "}" * 98
    %({"contract_version":1,"idempotency_key":"#{key}","source_metadata":#{opening}1#{closing}})
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

    it "raises ArgumentError when endpoint is not a string" do
      expect { described_class.new(endpoint: 42, api_key:) }.to raise_error(ArgumentError, /endpoint must be a string/)
    end

    it "raises ArgumentError when api_key is not a string" do
      expect { described_class.new(endpoint:, api_key: 42) }.to raise_error(ArgumentError, /api_key must be a string/)
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

    it "raises ArgumentError when endpoint includes embedded credentials" do
      expect { described_class.new(endpoint: "https://user:pass@taskbridge-web.example.com/api", api_key:) }
        .to raise_error(ArgumentError, /valid http\(s\) URI/)
    end

    it "raises ArgumentError when endpoint includes a fragment" do
      expect { described_class.new(endpoint: "https://taskbridge-web.example.com/api#batch", api_key:) }
        .to raise_error(ArgumentError, /valid http\(s\) URI/)
    end

    it "raises ArgumentError when publisher_instance is not a string" do
      expect { described_class.new(endpoint:, api_key:, publisher_instance: 42) }
        .to raise_error(ArgumentError, /publisher_instance/)
    end

    it "raises ArgumentError when publisher_instance is a blank string" do
      expect { described_class.new(endpoint:, api_key:, publisher_instance: "") }
        .to raise_error(ArgumentError, /publisher_instance/)
    end

    it "raises ArgumentError when endpoint contains invalid UTF-8 byte sequences" do
      expect { described_class.new(endpoint: (+"https://ex\xffample.com").force_encoding("UTF-8"), api_key:) }
        .to raise_error(ArgumentError, /endpoint must be valid UTF-8/)
    end

    it "raises ArgumentError when api_key contains invalid UTF-8 byte sequences" do
      expect { described_class.new(endpoint:, api_key: (+"key\xff").force_encoding("UTF-8")) }
        .to raise_error(ArgumentError, /api_key must be valid UTF-8/)
    end

    it "raises ArgumentError when publisher_instance contains invalid UTF-8 byte sequences" do
      expect { described_class.new(endpoint:, api_key:, publisher_instance: (+"my-mac\xff").force_encoding("UTF-8")) }
        .to raise_error(ArgumentError, /publisher_instance must be valid UTF-8/)
    end
  end

  describe "#publish" do
    it "raises ArgumentError when entries array is empty" do
      expect { publisher.publish([]) }.to raise_error(ArgumentError, /must not be empty/)
    end

    it "wraps a single entry argument into a one-entry batch" do
      captured = stub_success_and_capture_request([entry])
      results = publisher.publish(entry)
      expect(results.length).to eq(1)
      expect(results.first).to be_accepted
      body = JSON.parse(captured[:request][:body], symbolize_names: true)
      expect(body[:items].length).to eq(1)
    end

    it "disables redirect following on the HTTP request" do
      captured = stub_success_and_capture_request([entry])

      publisher.publish(entry)

      expect(captured.dig(:request, :no_follow)).to be(true)
    end

    it "raises ArgumentError when an entry has an unknown record_kind" do
      bogus = make_entry(key: "tb:v1:bogus:1", kind: "bogus")
      expect { publisher.publish([bogus]) }.to raise_error(ArgumentError, /unknown record_kind/)
    end

    it "names the offending kind when an entry has a nil record_kind" do
      nil_kind = make_entry(key: "tb:v1:bogus:1", kind: nil)
      expect { publisher.publish([nil_kind]) }.to raise_error(ArgumentError, /unknown record_kind\(s\): nil/)
    end

    it "raises ArgumentError when an entry does not implement the entry interface" do
      expect { publisher.publish(["not an entry"]) }.to raise_error(ArgumentError, /entries must respond/)
    end

    it "does not send an HTTP request when an entry does not implement the entry interface" do
      allow(HTTParty).to receive(:post)
      expect { publisher.publish([Object.new]) }.to raise_error(ArgumentError, /entries must respond/)
      expect(HTTParty).not_to have_received(:post)
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

    context "when an entry carries no usable idempotency_key" do
      it "raises ArgumentError when an entry's idempotency_key is nil" do
        keyless = make_entry(key: nil)
        expect { publisher.publish([keyless]) }.to raise_error(ArgumentError, /non-blank string idempotency_key/)
      end

      it "raises ArgumentError when an entry's idempotency_key is a blank string" do
        blank = make_entry(key: "")
        expect { publisher.publish([blank]) }.to raise_error(ArgumentError, /non-blank string idempotency_key/)
      end

      it "raises ArgumentError when an entry's idempotency_key carries invalid UTF-8" do
        malformed = make_entry(
          key: (+"tb:v1:item:\xff").force_encoding("UTF-8"),
          payload: { contract_version: 1, source: {} }.to_json
        )
        expect { publisher.publish([malformed]) }.to raise_error(ArgumentError, /non-blank string idempotency_key/)
      end

      it "raises ArgumentError when an entry's idempotency_key cannot be transcoded to UTF-8 even though valid_encoding? is true" do
        untranscodable = make_entry(
          key: "😀".encode(Encoding.find("UTF8-DoCoMo")),
          payload: { contract_version: 1, source: {} }.to_json
        )
        expect { publisher.publish([untranscodable]) }.to raise_error(ArgumentError, /non-blank string idempotency_key/)
      end

      it "does not send an HTTP request" do
        allow(HTTParty).to receive(:post)
        keyless = make_entry(key: nil)
        expect { publisher.publish([keyless]) }.to raise_error(ArgumentError)
        expect(HTTParty).not_to have_received(:post)
      end
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

    it "raises ArgumentError when a stored payload carries a non-integer contract_version" do
      floaty = make_entry(
        key: "tb:v1:item:asana:default:9:snapshot:2026-08-14T19:00:00.000000Z",
        payload: { contract_version: 1.0, idempotency_key: "tb:v1:item:asana:default:9:snapshot:2026-08-14T19:00:00.000000Z" }.to_json
      )
      expect { publisher.publish([floaty]) }.to raise_error(ArgumentError, /payload contract_version/)
    end

    it "accepts a valid entry whose parsed_payload uses string keys" do
      string_keyed = instance_double(
        PublicationOutboxEntry,
        idempotency_key: entry.idempotency_key,
        record_kind: "item",
        parsed_payload: JSON.parse({ contract_version: 1, idempotency_key: entry.idempotency_key, source: {} }.to_json)
      )
      stub_http(
        status: 200,
        body: {
          contract_version: 1,
          accepted: 1,
          replayed: 0,
          rejected: 0,
          results: [{ record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" }]
        }
      )

      expect(publisher.publish([string_keyed]).first).to be_accepted
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

      it "raises ArgumentError when the payload is missing so JSON.parse raises TypeError" do
        missing = make_entry(key: "tb:v1:item:asana:default:7:snapshot:2026-08-14T19:00:00.000000Z")
        allow(missing).to receive(:parsed_payload).and_raise(TypeError, "no implicit conversion of nil into String")
        expect { publisher.publish([missing]) }.to raise_error(ArgumentError, /payload for .*asana:default:7.*is missing or unreadable/)
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

      it "raises ArgumentError naming the row when a payload parses but cannot be JSON-generated" do
        key = "tb:v1:item:asana:default:8:snapshot:2026-08-14T19:00:00.000000Z"
        raw = %({"contract_version":1,"idempotency_key":"#{key}","title":"milk }) << 0xff.chr << %("})
        binary = make_entry(key: key, payload: raw.force_encoding("UTF-8"))

        expect { publisher.publish([binary]) }
          .to raise_error(ArgumentError, /payload for .*asana:default:8.* is not serializable/)
      end

      it "does not send an HTTP request when a payload cannot be JSON-generated" do
        allow(HTTParty).to receive(:post)
        key = "tb:v1:item:asana:default:8:snapshot:2026-08-14T19:00:00.000000Z"
        raw = %({"contract_version":1,"idempotency_key":"#{key}","title":"milk }) << 0xff.chr << %("})
        binary = make_entry(key: key, payload: raw.force_encoding("UTF-8"))

        expect { publisher.publish([binary]) }.to raise_error(ArgumentError, /is not serializable/)
        expect(HTTParty).not_to have_received(:post)
      end

      # A row nested exactly at the JSON parse limit is storable and parses
      # fine, but exceeds the generation limit once the batch envelope wraps
      # it two levels deeper; the resulting NestingError must be classified
      # like any other unserializable row, not leak raw.
      it "raises ArgumentError naming the row when a payload nests too deeply to embed in a batch body" do
        key = "tb:v1:item:asana:default:10:snapshot:2026-08-14T19:00:00.000000Z"
        deep = make_entry(key: key, payload: deep_nested_payload(key))

        expect { publisher.publish([deep]) }
          .to raise_error(ArgumentError, /payload for .*asana:default:10.* is not serializable/)
      end

      it "does not send an HTTP request when a payload nests too deeply" do
        allow(HTTParty).to receive(:post)
        key = "tb:v1:item:asana:default:10:snapshot:2026-08-14T19:00:00.000000Z"
        deep = make_entry(key: key, payload: deep_nested_payload(key))

        expect { publisher.publish([deep]) }.to raise_error(ArgumentError, /is not serializable/)
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

      it "leaves error_code and message nil for accepted rows instead of empty strings" do
        result = publisher.publish([entry]).first
        expect(result.error_code).to be_nil
        expect(result.message).to be_nil
      end
    end

    context "when an accepted result carries a non-boolean retryable value" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{
              record_kind: "item",
              idempotency_key: entry.idempotency_key,
              status: "accepted",
              retryable: "false"
            }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of trusting malformed metadata on a success row" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /result retryable must be a boolean when provided/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when an accepted result carries non-string error details" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{
              record_kind: "item",
              idempotency_key: entry.idempotency_key,
              status: "accepted",
              error_code: 422,
              message: { detail: "bad row" }
            }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of coercing bogus success-row details" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /result error_code must be a string when provided/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when an accepted result carries a blank error_code" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{
              record_kind: "item",
              idempotency_key: entry.idempotency_key,
              status: "accepted",
              error_code: "   "
            }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of accepting blank success-row metadata" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /result error_code must be a non-blank string when provided/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the server returns 200 with a replayed result" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 0, replayed: 1, rejected: 0,
            results: [{ record_kind: "item", idempotency_key: entry.idempotency_key, status: "replayed" }]
          }
        )
      end

      it "marks the result as replayed" do
        expect(publisher.publish([entry]).first).to be_replayed
      end
    end

    context "when a replayed result carries a non-string message" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 0, replayed: 1, rejected: 0,
            results: [{
              record_kind: "item",
              idempotency_key: entry.idempotency_key,
              status: "replayed",
              message: { detail: "already seen" }
            }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of trusting malformed replay metadata" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /result message must be a string when provided/
        ) { |e| expect(e.retryable).to be true }
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
              record_kind: "item",
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
              record_kind: "item",
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
          Publication::DeliveryError, /rejected result must carry a boolean retryable/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a rejected result omits retryable" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 0, replayed: 0, rejected: 1,
            results: [{
              record_kind: "item",
              idempotency_key: entry.idempotency_key,
              status: "rejected",
              error_code: "validation_error",
              message: "bad row"
            }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of leaving retry policy undefined" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /rejected result must carry a boolean retryable/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a rejected result omits error_code" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 0, replayed: 0, rejected: 1,
            results: [{
              record_kind: "item",
              idempotency_key: entry.idempotency_key,
              status: "rejected",
              retryable: false,
              message: "bad row"
            }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of leaving rejection classification undefined" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /rejected result must carry a non-blank string error_code/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a rejected result carries a non-string error_code" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 0, replayed: 0, rejected: 1,
            results: [{
              record_kind: "item",
              idempotency_key: entry.idempotency_key,
              status: "rejected",
              retryable: false,
              error_code: 422,
              message: "bad row"
            }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of coercing the value" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /rejected result must carry a non-blank string error_code/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a rejected result carries a non-string message" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 0, replayed: 0, rejected: 1,
            results: [{
              record_kind: "item",
              idempotency_key: entry.idempotency_key,
              status: "rejected",
              retryable: false,
              error_code: "validation_error",
              message: { detail: "bad row" }
            }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of coercing the value" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /rejected result message must be a string/
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

    context "when the server returns 403" do
      before { stub_http(status: 403, body: "Forbidden") }

      it "raises a non-retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /authorization failure/
        ) { |e| expect(e.retryable).to be false }
      end
    end

    context "when the server returns string status codes like Net::HTTP" do
      before { stub_http(status: 401, body: "Unauthorized") }

      it "classifies them using their numeric value" do
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
        204 => true,
        302 => true,
        400 => false,
        404 => false,
        408 => true,
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

    context "when the response code is missing" do
      before do
        allow(HTTParty).to receive(:post).and_return(
          instance_double(HTTParty::Response, code: nil, body: "upstream proxy error")
        )
      end

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(Publication::DeliveryError) do |e|
          expect(e.retryable).to be true
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

    context "when the HTTP stack raises a generic Timeout::Error" do
      before { allow(HTTParty).to receive(:post).and_raise(Timeout::Error, "execution expired") }

      it "classifies the timeout as a retryable DeliveryError" do
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

    context "when the endpoint redirects too deeply" do
      before { allow(HTTParty).to receive(:post).and_raise(HTTParty::RedirectionTooDeep.new("redirect too deep")) }

      it "raises a retryable DeliveryError instead of leaking the raw exception" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /transport error/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the connection breaks while writing the request body" do
      before { allow(HTTParty).to receive(:post).and_raise(Errno::EPIPE, "Broken pipe") }

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /transport error/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the network is unreachable" do
      before { allow(HTTParty).to receive(:post).and_raise(Errno::ENETUNREACH, "Network is unreachable") }

      it "classifies any Errno syscall failure as a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /transport error/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a compressed response body is corrupt" do
      before { allow(HTTParty).to receive(:post).and_raise(Zlib::DataError, "invalid compressed data") }

      it "classifies the Zlib failure as a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /transport error/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the endpoint answers with a malformed HTTP status line" do
      before { allow(HTTParty).to receive(:post).and_raise(Net::HTTPBadResponse, "wrong status line") }

      it "classifies the bad response as a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /transport error/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the endpoint violates the wire protocol mid-stream" do
      before { allow(HTTParty).to receive(:post).and_raise(Net::ProtoRetriableError, "protocol error") }

      it "classifies every Net::ProtocolError subclass as a retryable DeliveryError" do
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
          Publication::DeliveryError, /batch_id missing or mismatched/
        ) { |e| expect(e.retryable).to be true }
      end

      it "redacts secrets from the echoed batch_id in the error message" do
        allow(HTTParty).to receive(:post).and_return(
          instance_double(
            HTTParty::Response,
            code: "200",
            body: {
              batch_id: "Authorization: Bearer #{api_key}",
              contract_version: 1,
              accepted: 0,
              replayed: 0,
              rejected: 0,
              results: []
            }.to_json
          )
        )

        expect { publisher.publish([entry]) }.to raise_error(Publication::DeliveryError) { |error|
          expect(error.message).to include('got "Authorization: [REDACTED]"')
          expect(error.message).not_to include(api_key)
        }
      end

      it "redacts secrets nested in malformed hash keys before surfacing the echoed value" do
        allow(HTTParty).to receive(:post).and_return(
          instance_double(
            HTTParty::Response,
            code: "200",
            body: {
              batch_id: { "Authorization: Bearer #{api_key}" => { "refresh_token" => api_key } },
              contract_version: 1,
              accepted: 0,
              replayed: 0,
              rejected: 0,
              results: []
            }.to_json
          )
        )

        expect { publisher.publish([entry]) }.to raise_error(Publication::DeliveryError) { |error|
          expect(error.message).to include('{"Authorization: [REDACTED]" => {"refresh_token" => "[REDACTED]"}}')
          expect(error.message).not_to include(api_key)
        }
      end
    end

    context "when the response omits batch_id" do
      before do
        stub_http(
          status: 200,
          body: {
            contract_version: 1,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{ record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" }]
          },
          echo_batch_id: false
        )
      end

      it "raises a retryable DeliveryError instead of trusting an unreconcilable success body" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /batch_id missing or mismatched/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the response echoes contract_version as a float" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1.0,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{ record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of trusting a non-integer version" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /contract_version missing or mismatched/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the response omits contract_version" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x",
            accepted: 1, replayed: 0, rejected: 0,
            results: [{ record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of trusting an unversioned success body" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /contract_version missing or mismatched/
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

    context "when a result carries a non-string idempotency_key" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{ record_kind: "item", idempotency_key: 123, status: "accepted" }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of treating the row as missing" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /result missing idempotency_key/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a result carries an invalid-UTF-8 idempotency_key" do
      before do
        allow(HTTParty).to receive(:post) do |_endpoint, opts|
          raw = %({"batch_id":"#{opts[:headers]['X-TaskBridge-Batch-Id']}","contract_version":1,) <<
                %("accepted":1,"replayed":0,"rejected":0,"results":[{) <<
                %("record_kind":"item","idempotency_key":"tb:v1:item:\xff","status":"accepted"}]})
          instance_double(HTTParty::Response, code: 200, body: raw.force_encoding("UTF-8"))
        end
      end

      it "raises a retryable DeliveryError instead of trying to reconcile a malformed key" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /result missing idempotency_key/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    it "sends required contract headers to the endpoint" do
      stub_http(
        status: 200,
        body: {
          batch_id: "x", contract_version: 1,
          accepted: 1, replayed: 0, rejected: 0,
          results: [{ record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" }]
        }
      )
      publisher.publish([entry])
      expect(HTTParty).to have_received(:post).with(
        endpoint,
        hash_including(
          headers: hash_including(
            "Accept" => "application/json",
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
          results: [{ record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" }]
        }
      )
      described_class.new(endpoint:, api_key:, timeout: 5).publish([entry])
      expect(HTTParty).to have_received(:post).with(endpoint, hash_including(timeout: 5))
    end

    it "stamps every row in the batch with the same published_at" do
      second = make_entry(key: "tb:v1:item:asana:default:2:snapshot:2026-08-14T19:00:00.000000Z")
      rows = [entry, second]
      captured = stub_success_and_capture_request(rows)

      publisher.publish(rows)

      body = JSON.parse(captured[:request][:body], symbolize_names: true)
      timestamps = body[:items].map { |item| item[:published_at] }
      expect(timestamps).to all(be_present)
      expect(timestamps.uniq.length).to eq(1)
    end

    it "replaces stale published_at transport metadata on string-keyed payloads" do
      stale_payload = instance_double(
        PublicationOutboxEntry,
        idempotency_key: entry.idempotency_key,
        record_kind: "item",
        parsed_payload: JSON.parse(
          {
            contract_version: 1,
            idempotency_key: entry.idempotency_key,
            source: {},
            published_at: "2026-08-01T00:00:00.000000Z"
          }.to_json
        )
      )
      captured = stub_success_and_capture_request([stale_payload])

      publisher.publish([stale_payload])

      body = JSON.parse(captured[:request][:body])
      item = body.fetch("items").fetch(0)
      expect(item.keys.count("published_at")).to eq(1)
      expect(item.fetch("published_at")).not_to eq("2026-08-01T00:00:00.000000Z")
    end

    it "describes one publish attempt with a single instant across envelope and rows" do
      captured = stub_success_and_capture_request([entry])

      publisher.publish([entry])

      body = JSON.parse(captured[:request][:body], symbolize_names: true)
      expect(body[:items].first[:published_at]).to eq(body[:batch][:sent_at])
    end

    it "routes each record kind into its contract array with published_at stamped" do
      observation = make_entry(key: "tb:v1:obs:asana:default:1:source_changed:2026-08-14T19:00:00.000000Z", kind: "observation")
      mapping = make_entry(key: "tb:v1:map:sync_collection:84:membership:asana:default:1:2026-08-14T19:00:00.000000Z", kind: "mapping")
      sync_run = make_entry(key: "tb:v1:sync_run:asana:default:run-1", kind: "sync_run")
      rows = [entry, observation, mapping, sync_run]
      captured = stub_success_and_capture_request(rows)

      publisher.publish(rows)

      body = JSON.parse(captured[:request][:body], symbolize_names: true)
      expect(body[:items].map { |r| r[:idempotency_key] }).to contain_exactly(entry.idempotency_key)
      expect(body[:observations].map { |r| r[:idempotency_key] }).to contain_exactly(observation.idempotency_key)
      expect(body[:mappings].map { |r| r[:idempotency_key] }).to contain_exactly(mapping.idempotency_key)
      expect(body[:sync_runs].map { |r| r[:idempotency_key] }).to contain_exactly(sync_run.idempotency_key)
      all_rows = body.values_at(:items, :observations, :mappings, :sync_runs).flatten
      expect(all_rows.map { |r| r[:published_at] }).to all(be_present)
    end

    it "keeps batch headers consistent with the body envelope per the contract" do
      captured = stub_success_and_capture_request([entry])

      publisher.publish([entry])

      request = captured[:request]
      body = JSON.parse(request[:body], symbolize_names: true)
      headers = request[:headers]
      expect(headers["X-TaskBridge-Contract-Version"]).to eq(body[:contract_version].to_s)
      expect(headers["X-TaskBridge-Batch-Id"]).to eq(body[:batch][:batch_id])
      expect(headers["X-TaskBridge-Sent-At"]).to eq(body[:batch][:sent_at])
    end

    context "when the response body is not valid JSON" do
      before { stub_http(status: 200, body: "not json") }

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a 200 response has a nil body" do
      before do
        allow(HTTParty).to receive(:post).and_return(
          instance_double(HTTParty::Response, code: 200, body: nil)
        )
      end

      it "raises a retryable DeliveryError instead of a TypeError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /unparseable response body/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a 200 response has an empty body" do
      before { stub_http(status: 200, body: "") }

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /unparseable response body/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the response returns the wrong result idempotency_key" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{ record_kind: "item", idempotency_key: "tb:v1:item:other:1", status: "accepted" }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of trusting the mismatched result set" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /result idempotency_key set mismatch/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when mixed-kind entries are submitted" do
      let(:observation) do
        make_entry(
          key: "tb:v1:obs:asana:default:1:source_changed:2026-08-14T19:00:00.000000Z",
          kind: "observation"
        )
      end

      before do
        allow(HTTParty).to receive(:post) do |_endpoint, options|
          body = JSON.parse(options[:body], symbolize_names: true)
          wire_order = [
            *body.fetch(:items).map { |row| ["item", row] },
            *body.fetch(:observations).map { |row| ["observation", row] },
            *body.fetch(:mappings).map { |row| ["mapping", row] },
            *body.fetch(:sync_runs).map { |row| ["sync_run", row] }
          ]

          instance_double(
            HTTParty::Response,
            code: "200",
            body: {
              batch_id: options[:headers]["X-TaskBridge-Batch-Id"],
              contract_version: 1,
              accepted: wire_order.length,
              replayed: 0,
              rejected: 0,
              results: wire_order.map do |record_kind, row|
                {
                  record_kind:,
                  idempotency_key: row.fetch(:idempotency_key),
                  status: "accepted"
                }
              end
            }.to_json
          )
        end
      end

      it "accepts a response in transmitted wire order and returns results in caller order" do
        results = publisher.publish([observation, entry])

        expect(results.map(&:entry)).to eq([observation, entry])
        expect(results).to all(be_accepted)
      end
    end

    context "when the response returns results out of submission order" do
      let(:second) { make_entry(key: "tb:v1:item:asana:default:2:snapshot:2026-08-14T19:00:00.000000Z") }

      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 2, replayed: 0, rejected: 0,
            results: [
              { record_kind: "item", idempotency_key: second.idempotency_key, status: "accepted" },
              { record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" }
            ]
          }
        )
      end

      it "raises a retryable DeliveryError instead of silently reordering the response" do
        expect { publisher.publish([entry, second]) }.to raise_error(
          Publication::DeliveryError, /results are not in submission order/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the response repeats an idempotency_key across results" do
      let(:second) { make_entry(key: "tb:v1:item:asana:default:2:snapshot:2026-08-14T19:00:00.000000Z") }

      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 2, replayed: 0, rejected: 0,
            results: [
              { record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" },
              { record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" }
            ]
          }
        )
      end

      it "raises a retryable DeliveryError instead of trusting an ambiguous response" do
        expect { publisher.publish([entry, second]) }.to raise_error(
          Publication::DeliveryError, /duplicate idempotency_key\(s\) in results/
        ) { |e| expect(e.retryable).to be true }
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

    context "when a result is missing its idempotency_key" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{ record_kind: "item", status: "accepted" }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of orphaning the row" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /unreconcilable response: result missing idempotency_key/
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
              { record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" },
              { record_kind: "item", idempotency_key: "tb:v1:item:other:1", status: "accepted" }
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
            results: [{ record_kind: "item", idempotency_key: entry.idempotency_key, status: "queued" }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of acting on the status" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /unknown result status/
        ) { |e| expect(e.retryable).to be true }
      end

      it "redacts secrets from the rejected status value in the error message" do
        allow(HTTParty).to receive(:post) do |_endpoint, options|
          instance_double(
            HTTParty::Response,
            code: "200",
            body: {
              batch_id: options[:headers]["X-TaskBridge-Batch-Id"],
              contract_version: 1,
              accepted: 1,
              replayed: 0,
              rejected: 0,
              results: [{
                record_kind: "item",
                idempotency_key: entry.idempotency_key,
                status: "Bearer #{api_key}"
              }]
            }.to_json
          )
        end

        expect { publisher.publish([entry]) }.to raise_error(Publication::DeliveryError) { |error|
          expect(error.message).to include(%(unknown result status "Bearer [REDACTED]"))
          expect(error.message).not_to include(api_key)
        }
      end
    end

    context "when the response echoes a different contract version" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 2,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{ record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" }]
          }
        )
      end

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /contract_version missing or mismatched/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a result omits record_kind" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{ idempotency_key: entry.idempotency_key, status: "accepted" }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of trusting the malformed result" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /result record_kind must be one of/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a result carries an unknown record_kind" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{ record_kind: "mystery", idempotency_key: entry.idempotency_key, status: "accepted" }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of trusting the malformed result" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /result record_kind must be one of/
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
              { record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" },
              { record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" }
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
            results: [{ record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" }]
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
          body: { batch_id: "x", contract_version: 1, results: [{ record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" }] }
        )
      end

      it "raises a retryable DeliveryError" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /unreconcilable response/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the count fields are negative but still sum to the result count" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: -1, replayed: 0, rejected: 2,
            results: [{ record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of trusting the counts" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /unreconcilable response/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the declared counts contradict the per-row statuses" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 1, replayed: 0, rejected: 0,
            results: [{
              record_kind: "item",
              idempotency_key: entry.idempotency_key,
              status: "rejected",
              retryable: false,
              error_code: "validation_error",
              message: "bad row"
            }]
          }
        )
      end

      it "raises a retryable DeliveryError instead of trusting the response" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /unreconcilable response/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when a rejected result carries malformed UTF-8 in its message" do
      before do
        allow(HTTParty).to receive(:post) do |_endpoint, opts|
          raw = %({"batch_id":"#{opts[:headers]['X-TaskBridge-Batch-Id']}","contract_version":1,) <<
                %("accepted":0,"replayed":0,"rejected":1,"results":[{) <<
                %("record_kind":"item","idempotency_key":"#{entry.idempotency_key}","status":"rejected","retryable":false,) <<
                %("error_code":"validation_error","message":"bad \xff"}]})
          instance_double(HTTParty::Response, code: 200, body: raw.force_encoding("UTF-8"))
        end
      end

      it "sanitizes the message so it is safe to log and persist" do
        result = publisher.publish([entry]).first
        expect(result).to be_rejected
        expect(result.message.valid_encoding?).to be true
        expect(result.message).to include("bad")
      end

      it "sanitizes the error_code the same way" do
        allow(HTTParty).to receive(:post) do |_endpoint, opts|
          raw = %({"batch_id":"#{opts[:headers]['X-TaskBridge-Batch-Id']}","contract_version":1,) <<
                %("accepted":0,"replayed":0,"rejected":1,"results":[{) <<
                %("record_kind":"item","idempotency_key":"#{entry.idempotency_key}","status":"rejected","retryable":false,) <<
                %("error_code":"boom \xff","message":"bad row"}]})
          instance_double(HTTParty::Response, code: 200, body: raw.force_encoding("UTF-8"))
        end

        result = publisher.publish([entry]).first
        expect(result.error_code.valid_encoding?).to be true
      end
    end

    context "when a result's idempotency_key carries malformed UTF-8" do
      before do
        allow(HTTParty).to receive(:post) do |_endpoint, opts|
          raw = %({"batch_id":"#{opts[:headers]['X-TaskBridge-Batch-Id']}","contract_version":1,) <<
                %("accepted":1,"replayed":0,"rejected":0,"results":[{) <<
                %("record_kind":"item","idempotency_key":"tb:v1:key\xff","status":"accepted"}]})
          instance_double(HTTParty::Response, code: 200, body: raw.force_encoding("UTF-8"))
        end
      end

      it "raises a retryable DeliveryError instead of trying to reconcile a malformed key" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /result missing idempotency_key/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when the response mixes a missing submitted key with an unexpected key" do
      let(:second) { make_entry(key: "tb:v1:item:asana:default:2:snapshot:2026-08-14T19:01:00.000000Z") }

      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 2, replayed: 0, rejected: 0,
            results: [
              { record_kind: "item", idempotency_key: entry.idempotency_key, status: "accepted" },
              { record_kind: "item", idempotency_key: "tb:v1:item:other:2", status: "accepted" }
            ]
          }
        )
      end

      it "raises a retryable DeliveryError naming both sides of the mismatch" do
        expect { publisher.publish([entry, second]) }.to raise_error(
          Publication::DeliveryError, /missing .*#{Regexp.escape(second.idempotency_key)}.*unexpected .*tb:v1:item:other:2/
        ) { |e| expect(e.retryable).to be true }
      end
    end

    context "when an echoed batch_id carries malformed UTF-8" do
      before do
        raw = (+"{\"batch_id\":\"bad\xff\",\"contract_version\":1,\"accepted\":0,\"replayed\":0,\"rejected\":0,\"results\":[]}")
        allow(HTTParty).to receive(:post).and_return(
          instance_double(HTTParty::Response, code: 200, body: raw.force_encoding("UTF-8"))
        )
      end

      it "raises a DeliveryError whose message is valid UTF-8" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /batch_id missing or mismatched/
        ) { |e| expect(e.message.valid_encoding?).to be true }
      end
    end

    context "when an echoed contract_version is a malformed UTF-8 string" do
      before do
        allow(HTTParty).to receive(:post) do |_endpoint, opts|
          raw = "{\"batch_id\":\"#{opts[:headers]['X-TaskBridge-Batch-Id']}\"," <<
                %("contract_version":"v\xff","accepted":0,"replayed":0,"rejected":0,"results":[]})
          instance_double(HTTParty::Response, code: 200, body: raw.force_encoding("UTF-8"))
        end
      end

      it "raises a DeliveryError whose message is valid UTF-8" do
        expect { publisher.publish([entry]) }.to raise_error(
          Publication::DeliveryError, /contract_version missing or mismatched/
        ) { |e| expect(e.message.valid_encoding?).to be true }
      end
    end

    context "when an unparseable stored payload quotes malformed bytes in the parser error" do
      it "raises an ArgumentError whose message is valid UTF-8" do
        corrupt = make_entry(key: "tb:v1:item:asana:default:11:snapshot:2026-08-14T19:00:00.000000Z")
        allow(corrupt).to receive(:parsed_payload).and_raise(
          JSON::ParserError, (+"unexpected token at '\xff'").force_encoding("UTF-8")
        )
        expect { publisher.publish([corrupt]) }.to raise_error(ArgumentError, /unparseable payload/) do |e|
          expect(e.message.valid_encoding?).to be true
        end
      end
    end

    context "when a non-200 response body contains malformed UTF-8" do
      before do
        allow(HTTParty).to receive(:post).and_return(
          instance_double(HTTParty::Response, code: 422, body: (+"err\xff").force_encoding("UTF-8"))
        )
      end

      it "raises a DeliveryError whose message is valid UTF-8" do
        expect { publisher.publish([entry]) }.to raise_error(Publication::DeliveryError) do |e|
          expect(e.message.valid_encoding?).to be true
        end
      end
    end

    context "when a non-200 response body is huge" do
      before do
        allow(HTTParty).to receive(:post).and_return(
          instance_double(HTTParty::Response, code: 422, body: "x" * 100_000)
        )
      end

      it "bounds the embedded excerpt so the error message stays loggable" do
        expect { publisher.publish([entry]) }.to raise_error(Publication::DeliveryError) do |e|
          expect(e.message.length).to be < 600
        end
      end
    end

    context "when a non-200 response body echoes the API key back" do
      before do
        allow(HTTParty).to receive(:post).and_return(
          instance_double(HTTParty::Response, code: 422, body: %({"error":"echo Authorization: Bearer #{api_key}"}))
        )
      end

      it "redacts the credential from the DeliveryError message" do
        expect { publisher.publish([entry]) }.to raise_error(Publication::DeliveryError) do |e|
          expect(e.message).not_to include(api_key)
          expect(e.message).to include("[REDACTED]")
        end
      end
    end

    context "when a non-200 response body includes secret-bearing headers and cookies" do
      before do
        allow(HTTParty).to receive(:post).and_return(
          instance_double(
            HTTParty::Response,
            code: 422,
            body: "Authorization: Bearer reflected-token\nSet-Cookie: session=abc123\ncookie: prefs=secret"
          )
        )
      end

      it "redacts the reflected secrets from the DeliveryError message" do
        expect { publisher.publish([entry]) }.to raise_error(Publication::DeliveryError) do |e|
          expect(e.message).not_to include("reflected-token")
          expect(e.message).not_to include("session=abc123")
          expect(e.message).not_to include("prefs=secret")
          expect(e.message).to include("Authorization: [REDACTED]")
          expect(e.message).to include("Set-Cookie: [REDACTED]")
          expect(e.message).to include("cookie: [REDACTED]")
        end
      end
    end

    context "when a rejected row message echoes the API key back" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 0, replayed: 0, rejected: 1,
            results: [{
              record_kind: "item",
              idempotency_key: entry.idempotency_key,
              status: "rejected",
              retryable: false,
              error_code: "validation_error: #{api_key}",
              message: "saw Bearer #{api_key} in your headers"
            }]
          }
        )
      end

      it "redacts the credential from the result's message and error_code" do
        result = publisher.publish([entry]).first
        expect(result).to be_rejected
        expect(result.message).not_to include(api_key)
        expect(result.message).to include("[REDACTED]")
        expect(result.error_code).not_to include(api_key)
      end
    end

    context "when a rejected row returns secret-bearing operational text" do
      before do
        stub_http(
          status: 200,
          body: {
            batch_id: "x", contract_version: 1,
            accepted: 0, replayed: 0, rejected: 1,
            results: [{
              record_kind: "item",
              idempotency_key: entry.idempotency_key,
              status: "rejected",
              retryable: false,
              error_code: "Set-Cookie: session=abc123",
              message: "Authorization: Bearer reflected-token; cookie: prefs=secret"
            }]
          }
        )
      end

      it "redacts the reflected secrets from row-level error text" do
        result = publisher.publish([entry]).first
        expect(result).to be_rejected
        expect(result.error_code).to eq("Set-Cookie: [REDACTED]")
        expect(result.message).to include("Authorization: [REDACTED]")
        expect(result.message).to include("cookie: [REDACTED]")
        expect(result.message).not_to include("reflected-token")
        expect(result.message).not_to include("prefs=secret")
      end
    end

    context "when an unparseable response body echoes the API key back" do
      before do
        allow(HTTParty).to receive(:post).and_return(
          instance_double(HTTParty::Response, code: 200, body: %({#{api_key} not valid json}))
        )
      end

      it "redacts the credential from the parser error excerpt" do
        expect { publisher.publish([entry]) }.to raise_error(Publication::DeliveryError, /unparseable response body/) do |e|
          expect(e.message).not_to include(api_key)
        end
      end
    end
  end
end
