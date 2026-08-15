# frozen_string_literal: true

require "rails_helper"

RSpec.describe Publication::Batch do
  let(:source) { { service_type: "asana", service_instance: "asana:workspace-12345:default", external_id: "1" } }

  def build_item(key: "tb:v1:item:asana:workspace-12345:default:1:snapshot:2026-08-14T19:20:00.000000Z")
    Publication::ItemSnapshot.new(
      idempotency_key: key,
      item_key: "asana:workspace-12345:default:1",
      observed_at: "2026-08-14T19:20:00.000000Z",
      title: "Test task",
      status: "open",
      is_deleted: false,
      source:
    )
  end

  def build_observation(key: "tb:v1:obs:asana:workspace-12345:default:1:source_changed:2026-08-14T19:20:00.000000Z")
    Publication::Observation.new(
      idempotency_key: key,
      event_type: "source_changed",
      observed_at: "2026-08-14T19:20:00.000000Z",
      item_key: "asana:workspace-12345:default:1",
      source:
    )
  end

  def build_mapping(key: "tb:v1:map:sync_collection:84:membership:asana:workspace-12345:default:1:2026-08-14T19:20:00.000000Z")
    Publication::Mapping.new(
      idempotency_key: key,
      mapping_type: "representation_membership",
      observed_at: "2026-08-14T19:20:00.000000Z",
      sync_collection: { sync_collection_id: 84 },
      member: { item_key: "asana:workspace-12345:default:1", service_type: "asana", service_instance: source[:service_instance], external_id: "1" }
    )
  end

  def build_sync_run(key: "tb:v1:sync_run:asana:workspace-12345:default:run-1")
    Publication::SyncRunSummary.new(
      idempotency_key: key,
      sync_run_id: "run-1",
      service_type: "asana",
      service_instance: source[:service_instance],
      started_at: "2026-08-14T19:20:00.000000Z",
      finished_at: "2026-08-14T19:21:00.000000Z",
      last_attempted_at: "2026-08-14T19:20:00.000000Z",
      status: "success",
      items_synced: 1
    )
  end

  let(:batch_id)  { "2fd13f74-02ec-4dfd-b21c-3837a66a3768" }
  let(:sent_at)   { "2026-08-14T19:21:10.000000Z" }
  let(:item)      { build_item }

  describe "validation" do
    it "raises when batch_id is blank" do
      expect { described_class.new(batch_id: "", sent_at:, items: [item]) }.to raise_error(ArgumentError, /batch_id/)
    end

    it "raises when sent_at is nil" do
      expect { described_class.new(batch_id:, sent_at: nil, items: [item]) }.to raise_error(ArgumentError, /sent_at/)
    end

    it "raises when sent_at is a blank string" do
      expect { described_class.new(batch_id:, sent_at: "", items: [item]) }.to raise_error(ArgumentError, /sent_at/)
    end

    it "raises when sent_at is not parseable as ISO 8601" do
      expect { described_class.new(batch_id:, sent_at: "right now", items: [item]) }
        .to raise_error(ArgumentError, /invalid ISO 8601 timestamp/)
    end

    it "normalizes a Time sent_at to canonical UTC" do
      batch = described_class.new(batch_id:, sent_at: Time.utc(2026, 8, 14, 19, 21, 10), items: [item])
      expect(batch.to_payload[:batch][:sent_at]).to eq("2026-08-14T19:21:10.000000Z")
    end

    it "raises when all arrays are empty" do
      expect { described_class.new(batch_id:, sent_at:) }.to raise_error(ArgumentError, /at least one record/)
    end

    it "raises when two records share an idempotency_key" do
      expect do
        described_class.new(batch_id:, sent_at:, items: [item, build_item])
      end.to raise_error(ArgumentError, /duplicate idempotency_key/)
    end

    it "raises when the same idempotency_key appears across different arrays" do
      shared_key = "tb:v1:item:asana:workspace-12345:default:1:snapshot:2026-08-14T19:20:00.000000Z"
      observation = build_observation(key: shared_key)

      expect do
        described_class.new(batch_id:, sent_at:, items: [build_item(key: shared_key)], observations: [observation])
      end.to raise_error(ArgumentError, /duplicate idempotency_key/)
    end
  end

  describe "#to_payload" do
    subject(:payload) { described_class.new(batch_id:, sent_at:, items: [item]).to_payload }

    it "includes contract_version 1" do
      expect(payload[:contract_version]).to eq(Publication::Batch::CONTRACT_VERSION)
    end

    it "includes the batch envelope with batch_id and sent_at" do
      expect(payload[:batch][:batch_id]).to eq(batch_id)
      expect(payload[:batch][:sent_at]).to eq(sent_at)
    end

    it "includes the serialized item in the items array" do
      expect(payload[:items].length).to eq(1)
      expect(payload[:items].first[:idempotency_key]).to eq(item.idempotency_key)
    end

    it "serializes observations, mappings, and sync_runs into their own arrays" do
      observation = build_observation
      mapping = build_mapping
      run = build_sync_run
      batch = described_class.new(batch_id:, sent_at:, observations: [observation], mappings: [mapping], sync_runs: [run])

      payload = batch.to_payload
      expect(payload[:items]).to eq([])
      expect(payload[:observations].first[:idempotency_key]).to eq(observation.idempotency_key)
      expect(payload[:mappings].first[:idempotency_key]).to eq(mapping.idempotency_key)
      expect(payload[:sync_runs].first[:idempotency_key]).to eq(run.idempotency_key)
      expect(batch.total_record_count).to eq(3)
    end

    it "returns empty arrays for omitted record types" do
      expect(payload[:observations]).to eq([])
      expect(payload[:mappings]).to eq([])
      expect(payload[:sync_runs]).to eq([])
    end

    it "includes publisher_instance when provided" do
      batch = described_class.new(batch_id:, sent_at:, items: [item], publisher_instance: "my-mac")
      expect(batch.to_payload[:batch][:publisher_instance]).to eq("my-mac")
    end

    it "omits publisher when it is explicitly nil" do
      batch = described_class.new(batch_id:, sent_at:, items: [item], publisher: nil)
      expect(batch.to_payload[:batch].keys).not_to include(:publisher)
    end
  end

  describe "#total_record_count" do
    it "sums records across all arrays" do
      item2_key = "tb:v1:item:asana:workspace-12345:default:2:snapshot:2026-08-14T19:20:00.000000Z"
      item2 = build_item(key: item2_key)
      batch = described_class.new(batch_id:, sent_at:, items: [item, item2])
      expect(batch.total_record_count).to eq(2)
    end
  end
end
