# frozen_string_literal: true

require "rails_helper"

RSpec.describe PublicationOutboxEntry, type: :model do
  let(:source) { { service_type: "asana", service_instance: "asana:workspace-12345:default", external_id: "123" } }

  def build_item_snapshot(key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z")
    Publication::ItemSnapshot.new(
      idempotency_key: key,
      item_key: "asana:workspace-12345:default:123",
      observed_at: "2026-08-14T19:00:00.000000Z",
      title: "Test task",
      status: "open",
      is_deleted: false,
      source:
    )
  end

  def valid_entry_attrs
    {
      idempotency_key: "tb:v1:item:asana:default:1:snapshot:2026-08-14T19:00:00.000000Z",
      record_kind: "item",
      payload: { contract_version: 1, idempotency_key: "tb:v1:item:asana:default:1:snapshot:2026-08-14T19:00:00.000000Z" }.to_json
    }
  end

  describe "validations" do
    it "is valid with required fields" do
      entry = described_class.new(valid_entry_attrs)
      expect(entry).to be_valid
    end

    it "requires idempotency_key" do
      entry = described_class.new(valid_entry_attrs.merge(idempotency_key: ""))
      expect(entry).not_to be_valid
      expect(entry.errors[:idempotency_key]).to be_present
    end

    it "requires unique idempotency_key" do
      described_class.create!(valid_entry_attrs)
      duplicate = described_class.new(valid_entry_attrs)
      expect(duplicate).not_to be_valid
    end

    it "requires record_kind to be a known kind" do
      entry = described_class.new(valid_entry_attrs.merge(record_kind: "unknown"))
      expect(entry).not_to be_valid
    end

    it "requires payload" do
      entry = described_class.new(valid_entry_attrs.merge(payload: ""))
      expect(entry).not_to be_valid
    end
  end

  describe ".from_record" do
    it "builds an entry from a Publication::ItemSnapshot" do
      snapshot = build_item_snapshot
      entry = described_class.from_record(snapshot)

      expect(entry.idempotency_key).to eq(snapshot.idempotency_key)
      expect(entry.record_kind).to eq("item")
      expect(entry.service_type).to eq("asana")
      expect(entry.service_instance).to eq("asana:workspace-12345:default")
      expect(entry.status).to eq("pending")
    end

    it "stores JSON-serializable payload" do
      snapshot = build_item_snapshot
      entry = described_class.from_record(snapshot)
      expect { JSON.parse(entry.payload) }.not_to raise_error
    end

    it "extracts service_type and service_instance from the root for sync_run records" do
      run_summary = Publication::SyncRunSummary.new(
        idempotency_key: "tb:v1:sync_run:asana:workspace-12345:default:run-1",
        sync_run_id: "run-1",
        service_type: "asana",
        service_instance: "asana:workspace-12345:default",
        started_at: "2026-08-14T19:00:00.000000Z",
        finished_at: "2026-08-14T19:01:00.000000Z",
        last_attempted_at: "2026-08-14T19:00:00.000000Z",
        status: "success",
        items_synced: 5
      )
      entry = described_class.from_record(run_summary)

      expect(entry.record_kind).to eq("sync_run")
      expect(entry.service_type).to eq("asana")
      expect(entry.service_instance).to eq("asana:workspace-12345:default")
    end

    it "extracts service_type and service_instance from member for mapping records" do
      mapping = Publication::Mapping.new(
        idempotency_key: "tb:v1:map:sync_collection:84:membership:github:repo-1:issue-42:2026-08-14T19:21:00.000000Z",
        mapping_type: "representation_membership",
        observed_at: "2026-08-14T19:21:00.000000Z",
        sync_collection: { sync_collection_id: 84 },
        member: {
          item_key: "github:repo-1:issue-42",
          service_type: "github",
          service_instance: "github:repo-1",
          external_id: "issue-42"
        }
      )
      entry = described_class.from_record(mapping)

      expect(entry.record_kind).to eq("mapping")
      expect(entry.service_type).to eq("github")
      expect(entry.service_instance).to eq("github:repo-1")
    end
  end

  describe "scopes" do
    before do
      described_class.create!(valid_entry_attrs.merge(idempotency_key: "key-pending", status: "pending"))
      described_class.create!(valid_entry_attrs.merge(idempotency_key: "key-delivered", status: "delivered"))
      described_class.create!(valid_entry_attrs.merge(idempotency_key: "key-failed", status: "failed", retry_count: 2))
      described_class.create!(valid_entry_attrs.merge(idempotency_key: "key-terminal", status: "terminal", retry_count: 10))
    end

    it "pending returns only pending rows" do
      expect(described_class.pending.map(&:idempotency_key)).to eq(["key-pending"])
    end

    it "delivered returns only delivered rows" do
      expect(described_class.delivered.map(&:idempotency_key)).to eq(["key-delivered"])
    end

    it "retryable excludes terminal rows" do
      expect(described_class.retryable.map(&:idempotency_key)).to eq(["key-failed"])
    end

    it "publishable returns pending and retryable failed rows" do
      keys = described_class.publishable.map(&:idempotency_key)
      expect(keys).to include("key-pending", "key-failed")
      expect(keys).not_to include("key-terminal", "key-delivered")
    end
  end

  describe "#mark_delivered!" do
    it "sets status to delivered and records delivered_at" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_delivered!
      expect(entry.reload.status).to eq("delivered")
      expect(entry.delivered_at).to be_present
    end
  end

  describe "#mark_failed!" do
    it "increments retry_count and records failed_at" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_failed!(message: "network timeout")
      expect(entry.reload.retry_count).to eq(1)
      expect(entry.status).to eq("failed")
      expect(entry.error_message).to include("network timeout")
    end

    it "transitions to terminal when retry_count reaches MAX_RETRIES" do
      entry = described_class.create!(valid_entry_attrs.merge(retry_count: described_class::MAX_RETRIES - 1))
      entry.mark_failed!(message: "permanent error")
      expect(entry.reload.status).to eq("terminal")
    end
  end

  describe "#mark_replayed!" do
    it "sets status to delivered" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_replayed!
      expect(entry.reload.status).to eq("delivered")
    end
  end

  describe "#parsed_payload" do
    it "returns symbolized hash from payload JSON" do
      entry = described_class.new(valid_entry_attrs)
      expect(entry.parsed_payload).to be_a(Hash)
      expect(entry.parsed_payload[:contract_version]).to eq(1)
    end
  end
end
