# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::WebPublisher::Batch do
  let(:now) { Time.zone.parse("2026-10-05T12:00:00Z") }
  let(:observation) do
    OutboxEntry.new(
      idempotency_key: "tb:v1:obs:test_service:obs-1:snapshot_seen:2026-10-05T10:00:00.000000Z",
      record_kind: "observation",
      event_type: "snapshot_seen",
      service_type: "test_service",
      service_instance: "test_service",
      external_id: "obs-1",
      observed_at: now,
      payload: { contract_version: 1, item_key: "test_service:obs-1", observed_at: "2026-10-05T10:00:00.000000Z" }
    )
  end
  let(:mapping) do
    OutboxEntry.new(
      idempotency_key: "tb:v1:map:sync_collection:84:membership:test_service:obs-1:2026-10-05T10:00:00.000000Z",
      record_kind: "mapping",
      service_type: "test_service",
      service_instance: "test_service",
      external_id: "obs-1",
      observed_at: now,
      payload: { contract_version: 1, mapping_type: "representation_membership" }
    )
  end
  let(:sync_run) do
    OutboxEntry.new(
      idempotency_key: "tb:v1:sync_run:test_service:sync-run-20261005T100000Z-test_service",
      record_kind: "sync_run",
      service_type: "test_service",
      service_instance: "test_service",
      observed_at: now,
      payload: { contract_version: 1, status: "success", items_synced: 1 }
    )
  end

  describe "#headers" do
    it "sends the contract's auth and transport headers" do
      headers = described_class.new([observation], now:).headers(api_key: "secret")

      expect(headers).to include(
        "Authorization" => "Bearer secret",
        "Content-Type" => "application/json",
        "X-TaskBridge-Contract-Version" => "1"
      )
      expect(headers["X-TaskBridge-Batch-Id"]).to match(/\A[0-9a-f-]{36}\z/)
      expect(headers["X-TaskBridge-Sent-At"]).to eq("2026-10-05T12:00:00.000000Z")
    end
  end

  describe "#body" do
    it "groups rows into the contract's top-level arrays by record kind" do
      body = described_class.new([observation, mapping, sync_run], now:).body

      expect(body).to include(
        contract_version: 1,
        items: [],
        mappings: [hash_including("idempotency_key" => mapping.idempotency_key)],
        sync_runs: [hash_including("idempotency_key" => sync_run.idempotency_key, "status" => "success")]
      )
      expect(body[:observations]).to contain_exactly(hash_including("item_key" => "test_service:obs-1"))
    end

    it "keeps the batch metadata consistent with the transport headers" do
      batch = described_class.new([observation], now:)

      body = batch.body
      headers = batch.headers(api_key: "secret")

      expect(body.dig(:batch, :batch_id)).to eq(headers["X-TaskBridge-Batch-Id"])
      expect(body.dig(:batch, :sent_at)).to eq(headers["X-TaskBridge-Sent-At"])
      expect(body.dig(:batch, :publisher)).to eq("task_bridge")
      expect(body.dig(:batch, :publisher_instance)).to be_present
    end

    it "adds the row's idempotency key and transport timestamps to its immutable payload" do
      row = described_class.new([observation], now:).body[:observations].first

      expect(row).to include(
        "idempotency_key" => observation.idempotency_key,
        "contract_version" => 1,
        "published_at" => "2026-10-05T12:00:00.000000Z"
      )
      expect(row).not_to have_key(:item_key)
    end

    it "uses the row's payload_version as its batch and row contract version" do
      versioned = OutboxEntry.new(
        idempotency_key: "tb:v1:obs:test_service:obs-2:snapshot_seen:2026-10-05T10:00:00.000000Z",
        record_kind: "observation", service_type: "test_service",
        observed_at: now, payload_version: 2, payload: {}
      )

      batch = described_class.new([versioned], now:)
      row = batch.body[:observations].first

      expect(batch.body[:contract_version]).to eq(2)
      expect(batch.headers(api_key: "secret")["X-TaskBridge-Contract-Version"]).to eq("2")
      expect(row["contract_version"]).to eq(2)
    end
  end

  it "refuses to build an empty batch" do
    expect { described_class.new([], now:) }.to raise_error(ArgumentError, /empty batch/)
  end

  it "refuses to build a batch with mixed payload versions" do
    versioned = observation.dup
    versioned.payload_version = 2

    expect { described_class.new([observation, versioned], now:) }
      .to raise_error(ArgumentError, /mixed payload versions/)
  end
end
