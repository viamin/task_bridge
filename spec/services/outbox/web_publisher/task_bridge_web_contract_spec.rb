# frozen_string_literal: true

require "rails_helper"
require "pact_helper"

# Consumer-driven contract specs for Outbox::WebPublisher against the
# TaskBridge Web ingestion endpoint (issue #250, contract defined by
# RDR #215). Unlike the unit specs, these drive the real Net::HTTP transport
# (real Client, real Batch serialization, real Response/Reconciler reduction)
# against a Pact mock service, so the recorded pact reflects the publisher's
# actual behavior.
#
# Pact request matching rejects extra keys and mismatched array lengths, so
# the expected bodies below mirror exactly what Outbox::WebPublisher::Batch
# serializes; the committed pact file
# (spec/pacts/taskbridge-taskbridge_web.json) therefore pins the full v1
# wire shape for provider verification (viamin/task-bridge-web#189).
# RDR #215 requires regenerating the committed pact by running this whole
# file (docs/pact-consumer-contract-testing.md). Pact writes interactions in
# execution order, so pin the group to declaration order: a random global
# order would churn the committed pact file on every suite run.
RSpec.describe "TaskBridge Web ingestion batches", pact: true, order: :defined do
  let(:now) { Time.zone.parse("2026-10-05T12:00:00Z") }
  let(:api_key) { "pact-ingest-key" }
  let(:revoked_api_key) { "revoked-ingest-key" }
  let(:endpoint_path) { "/api/task_bridge/v1/ingestion/batches" }
  let(:item_key) do
    "tb:v1:item:asana:workspace-12345:default:1201234567890:snapshot:2026-10-05T10:00:00.000000Z"
  end
  let(:source_changed_key) do
    "tb:v1:obs:asana:workspace-12345:default:1201234567890:source_changed:2026-10-05T10:01:00.000000Z"
  end
  let(:snapshot_seen_key) do
    "tb:v1:obs:asana:workspace-12345:default:1201234567890:snapshot_seen:2026-10-05T10:02:00.000000Z"
  end
  let(:halved_first_key) do
    "tb:v1:obs:asana:workspace-12345:default:1201234567890:source_changed:2026-10-05T10:03:00.000000Z"
  end
  let(:halved_second_key) do
    "tb:v1:obs:asana:workspace-12345:default:1201234567890:source_changed:2026-10-05T10:04:00.000000Z"
  end
  let(:single_row_key) do
    "tb:v1:obs:asana:workspace-12345:default:1201234567890:source_changed:2026-10-05T10:05:00.000000Z"
  end
  let(:unauthorized_key) do
    "tb:v1:obs:asana:workspace-12345:default:1201234567890:source_changed:2026-10-05T10:06:00.000000Z"
  end
  let(:source) do
    {
      "service_type" => "asana",
      "service_instance" => "asana:workspace-12345:default",
      "external_id" => "1201234567890"
    }
  end
  let(:item_source) { source.merge("source_url" => "https://app.asana.com/0/12345/1201234567890") }
  let(:status_change) { { "field" => "status", "from" => "open", "to" => "completed" } }
  # The publisher's clock is frozen in these specs, so sent_at/published_at
  # are deterministic; the Term still documents the required wire format.
  let(:sent_at) do
    Pact::Term.new(
      matcher: /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/,
      generate: "2026-10-05T12:00:00.000000Z"
    )
  end
  let(:batch_id) do
    Pact::Term.new(
      matcher: /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/,
      generate: "2fd13f74-02ec-4dfd-b21c-3837a66a3768"
    )
  end
  let(:json_content_type) { { "Content-Type" => "application/json" } }
  let(:config) do
    Outbox::WebPublisher::Config.resolve(
      "enabled" => true,
      "base_url" => task_bridge_web.mock_service_base_url,
      "api_key" => api_key,
      "batch_size" => 3
    )
  end

  def publish
    Outbox::WebPublisher.run!(config:, now:)
  end

  # RDR #215: omitted top-level arrays are equivalent to empty ones, but the
  # publisher always sends all four; the pact expects the same.
  def batch_body(items:, observations:)
    {
      "contract_version" => 1,
      "batch" => {
        "batch_id" => batch_id,
        "sent_at" => sent_at,
        "publisher" => "task_bridge",
        "publisher_instance" => Pact::SomethingLike.new("task-bridge")
      },
      "items" => items,
      "observations" => observations,
      "mappings" => [],
      "sync_runs" => []
    }
  end

  def item_row
    {
      "contract_version" => 1,
      "idempotency_key" => item_key,
      "item_key" => "asana:workspace-12345:default:1201234567890",
      "entity_type" => "task",
      "observed_at" => "2026-10-05T10:00:00.000000Z",
      "published_at" => sent_at,
      "title" => "Buy milk",
      "status" => "open",
      "is_deleted" => false,
      "source" => item_source
    }
  end

  def observation_row(key:, event_type:, observed_at:, change: nil)
    row = {
      "contract_version" => 1,
      "idempotency_key" => key,
      "event_type" => event_type,
      "observed_at" => observed_at,
      "published_at" => sent_at,
      "item_key" => "asana:workspace-12345:default:1201234567890",
      "source" => source
    }
    change ? row.merge("change" => change) : row
  end

  def accepted_result(key, record_kind: "observation")
    { "record_kind" => record_kind, "idempotency_key" => key, "status" => "accepted" }
  end

  def results_body(results, accepted:, replayed:, rejected:)
    {
      "batch_id" => batch_id,
      "contract_version" => 1,
      "accepted" => Pact::SomethingLike.new(accepted),
      "replayed" => Pact::SomethingLike.new(replayed),
      "rejected" => Pact::SomethingLike.new(rejected),
      "results" => results
    }
  end

  def error_body(message)
    { "error" => { "message" => Pact::SomethingLike.new(message) } }
  end

  def auth_headers(key)
    {
      "Authorization" => "Bearer #{key}",
      "Content-Type" => "application/json",
      "X-TaskBridge-Contract-Version" => "1",
      "X-TaskBridge-Batch-Id" => batch_id,
      "X-TaskBridge-Sent-At" => sent_at
    }
  end

  def expected_post(body)
    { method: :post, path: endpoint_path, headers: auth_headers(api_key), body: }
  end

  def create_item_entry
    OutboxEntry.create!(
      idempotency_key: item_key,
      record_kind: "item",
      service_type: "asana",
      service_instance: "asana:workspace-12345:default",
      external_id: "1201234567890",
      observed_at: "2026-10-05T10:00:00.000000Z",
      payload: item_row.except("idempotency_key", "published_at")
    )
  end

  def create_observation_entry(key:, event_type:, observed_at:, change: nil)
    OutboxEntry.create!(
      idempotency_key: key,
      record_kind: "observation",
      event_type:,
      service_type: "asana",
      service_instance: "asana:workspace-12345:default",
      external_id: "1201234567890",
      observed_at:,
      payload: observation_row(key:, event_type:, observed_at:, change:)
               .except("idempotency_key", "published_at")
    )
  end

  it "publishes a v1 batch and reconciles the per-row results response" do
    source_changed_row = observation_row(key: source_changed_key, event_type: "source_changed",
                                         observed_at: "2026-10-05T10:01:00.000000Z", change: status_change)
    snapshot_seen_row = observation_row(key: snapshot_seen_key, event_type: "snapshot_seen",
                                        observed_at: "2026-10-05T10:02:00.000000Z")
    task_bridge_web
      .given("an empty ingestion outbox except an item snapshot for #{item_key} was already accepted")
      .upon_receiving("a v1 batch with an item snapshot and two observations")
      .with(expected_post(batch_body(items: [item_row],
                                     observations: [source_changed_row, snapshot_seen_row])))
      .will_respond_with(
        status: 200,
        headers: json_content_type,
        body: results_body(
          [
            { "record_kind" => "item", "idempotency_key" => item_key, "status" => "replayed" },
            accepted_result(source_changed_key),
            { "record_kind" => "observation", "idempotency_key" => snapshot_seen_key,
              "status" => "rejected", "retryable" => false, "error_code" => "validation_error",
              "message" => Pact::SomethingLike.new("change is not valid for snapshot_seen") }
          ],
          accepted: 1, replayed: 1, rejected: 1
        )
      )

    create_item_entry
    create_observation_entry(key: source_changed_key, event_type: "source_changed",
                             observed_at: "2026-10-05T10:01:00.000000Z", change: status_change)
    create_observation_entry(key: snapshot_seen_key, event_type: "snapshot_seen",
                             observed_at: "2026-10-05T10:02:00.000000Z")

    summary = publish

    expect(summary).to include(status: "published", batches: 1, delivered: 2, failed: 1)
    expect(OutboxEntry.find_by(idempotency_key: item_key)).to be_delivered
    expect(OutboxEntry.find_by(idempotency_key: source_changed_key)).to be_delivered
    rejected = OutboxEntry.find_by(idempotency_key: snapshot_seen_key)
    expect(rejected).to be_failed
    expect(rejected.error_class).to eq("validation_error")
    expect(rejected.error_message).to eq("change is not valid for snapshot_seen")
  end

  it "re-sends a 413 batch in halves down to single rows" do
    first_half = observation_row(key: halved_first_key, event_type: "source_changed",
                                 observed_at: "2026-10-05T10:03:00.000000Z")
    second_half = observation_row(key: halved_second_key, event_type: "source_changed",
                                  observed_at: "2026-10-05T10:04:00.000000Z")
    task_bridge_web
      .given("a one-row-per-batch ingestion limit")
      .upon_receiving("a two-row v1 observation batch over the limit")
      .with(expected_post(batch_body(items: [], observations: [first_half, second_half])))
      .will_respond_with(status: 413, headers: json_content_type,
                         body: error_body("batch payload exceeds the configured limit"))
    task_bridge_web
      .given("a one-row-per-batch ingestion limit")
      .upon_receiving("the first single-row half of a halved v1 batch")
      .with(expected_post(batch_body(items: [], observations: [first_half])))
      .will_respond_with(status: 200, headers: json_content_type,
                         body: results_body([accepted_result(halved_first_key)],
                                            accepted: 1, replayed: 0, rejected: 0))
    task_bridge_web
      .given("a one-row-per-batch ingestion limit")
      .upon_receiving("the second single-row half of a halved v1 batch")
      .with(expected_post(batch_body(items: [], observations: [second_half])))
      .will_respond_with(status: 200, headers: json_content_type,
                         body: results_body([accepted_result(halved_second_key)],
                                            accepted: 1, replayed: 0, rejected: 0))

    create_observation_entry(key: halved_first_key, event_type: "source_changed",
                             observed_at: "2026-10-05T10:03:00.000000Z")
    create_observation_entry(key: halved_second_key, event_type: "source_changed",
                             observed_at: "2026-10-05T10:04:00.000000Z")

    summary = publish

    expect(summary).to include(status: "published", batches: 3, delivered: 2)
  end

  it "keeps a single row that is still 413 rejected pending for retry" do
    single_row = observation_row(key: single_row_key, event_type: "source_changed",
                                 observed_at: "2026-10-05T10:05:00.000000Z")
    task_bridge_web
      .given("an ingestion limit that rejects even a single row")
      .upon_receiving("a single-row v1 observation batch that still exceeds the limit")
      .with(expected_post(batch_body(items: [], observations: [single_row])))
      .will_respond_with(status: 413, headers: json_content_type,
                         body: error_body("batch payload exceeds the configured limit"))

    entry = create_observation_entry(key: single_row_key, event_type: "source_changed",
                                     observed_at: "2026-10-05T10:05:00.000000Z")

    summary = publish

    expect(summary).to include(status: "incomplete", stopped_reason: "http_413",
                               batches: 1, retryable: 1)
    expect(entry.reload).to be_pending
  end

  context "when the configured API key has been revoked" do
    let(:api_key) { revoked_api_key }

    it "marks every row terminally failed on a 401" do
      unauthorized_row = observation_row(key: unauthorized_key, event_type: "source_changed",
                                         observed_at: "2026-10-05T10:06:00.000000Z")
      task_bridge_web
        .given("an ingestion API key that has been revoked")
        .upon_receiving("a v1 batch sent with a revoked API key")
        .with(expected_post(batch_body(items: [], observations: [unauthorized_row])))
        .will_respond_with(status: 401, headers: json_content_type,
                           body: error_body("invalid api key"))

      entry = create_observation_entry(key: unauthorized_key, event_type: "source_changed",
                                       observed_at: "2026-10-05T10:06:00.000000Z")

      summary = publish

      expect(summary).to include(status: "incomplete", stopped_reason: "http_401",
                                 batches: 1, failed: 1)
      row = entry.reload
      expect(row).to be_failed
      expect(row.error_class).to eq("http_401")
      expect(row.error_message).to eq("invalid api key")
    end
  end
end
