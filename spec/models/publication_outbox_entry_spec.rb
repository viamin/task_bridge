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

    it "returns validation errors instead of raising when payload is not a string" do
      entry = described_class.new(valid_entry_attrs)
      entry.define_singleton_method(:payload) { { invalid: true } }
      expect(entry).not_to be_valid
      expect(entry.errors[:payload]).to include("must be a string")
    end

    it "rejects a payload that is not valid JSON" do
      entry = described_class.new(valid_entry_attrs.merge(payload: "not json"))
      expect(entry).not_to be_valid
      expect(entry.errors[:payload]).to be_present
    end

    it "rejects a payload that is valid JSON but not an object" do
      entry = described_class.new(valid_entry_attrs.merge(payload: "[1, 2]"))
      expect(entry).not_to be_valid
      expect(entry.errors[:payload]).to include("must be a JSON object")
    end

    it "rejects a payload that is not valid UTF-8 even though JSON.parse accepts it" do
      payload = (+"{\"idempotency_key\": \"k\", \"title\": \"milk \xff\"}").force_encoding("UTF-8")
      entry = described_class.new(valid_entry_attrs.merge(payload: payload))
      expect(entry).not_to be_valid
      expect(entry.errors[:payload]).to include("must be valid UTF-8")
    end

    it "requires record_kind to be present" do
      entry = described_class.new(valid_entry_attrs.merge(record_kind: nil))
      expect(entry).not_to be_valid
      expect(entry.errors[:record_kind]).to be_present
    end

    it "requires status to be present" do
      entry = described_class.new(valid_entry_attrs.merge(status: nil))
      expect(entry).not_to be_valid
      expect(entry.errors[:status]).to be_present
    end

    it "returns validation errors instead of raising when idempotency_key carries invalid UTF-8" do
      entry = described_class.new(valid_entry_attrs.merge(idempotency_key: (+"tb:v1:\xff").force_encoding("UTF-8")))
      expect(entry).not_to be_valid
      expect(entry.errors[:idempotency_key]).to include("must be valid UTF-8")
    end

    it "returns validation errors instead of raising when record_kind or status carry invalid UTF-8" do
      kind = described_class.new(valid_entry_attrs.merge(record_kind: (+"item\xff").force_encoding("UTF-8")))
      expect(kind).not_to be_valid
      expect(kind.errors[:record_kind]).to include("must be valid UTF-8")

      status = described_class.new(valid_entry_attrs.merge(status: (+"pending\xff").force_encoding("UTF-8")))
      expect(status).not_to be_valid
      expect(status.errors[:status]).to include("must be valid UTF-8")
    end

    it "returns validation errors when an optional string column carries invalid UTF-8" do
      entry = described_class.new(
        valid_entry_attrs.merge(
          service_type: (+"asana\xff").force_encoding("UTF-8"),
          service_instance: (+"asana:workspace\xff").force_encoding("UTF-8"),
          error_message: (+"boom \xff").force_encoding("UTF-8")
        )
      )
      expect(entry).not_to be_valid
      expect(entry.errors[:service_type]).to include("must be valid UTF-8")
      expect(entry.errors[:service_instance]).to include("must be valid UTF-8")
      expect(entry.errors[:error_message]).to include("must be valid UTF-8")
    end
  end

  describe ".from_record" do
    it "raises a clear ArgumentError for a record that does not implement the record interface" do
      expect { described_class.from_record(Struct.new(:ignored).new(nil)) }
        .to raise_error(ArgumentError, /record must respond to to_payload/)
    end

    it "raises a clear ArgumentError for a record whose class does not define RECORD_KIND" do
      keyless = Class.new do
        def to_payload = {}
      end
      expect { described_class.from_record(keyless.new) }
        .to raise_error(ArgumentError, /record class must define RECORD_KIND/)
    end

    it "raises a clear ArgumentError for a record kind outside the contract" do
      bogus = Class.new do
        def to_payload = {}
      end
      bogus::RECORD_KIND = "bogus"
      expect { described_class.from_record(bogus.new) }
        .to raise_error(ArgumentError, /unknown record_kind: bogus/)
    end

    it "raises a clear ArgumentError when to_payload returns an array" do
      array_payload = Class.new do
        def to_payload = [1, 2]
      end
      array_payload::RECORD_KIND = "item"
      expect { described_class.from_record(array_payload.new) }
        .to raise_error(ArgumentError, /to_payload must return a hash/)
    end

    it "raises a clear ArgumentError when to_payload returns nil" do
      nil_payload = Class.new do
        def to_payload = nil
      end
      nil_payload::RECORD_KIND = "observation"
      expect { described_class.from_record(nil_payload.new) }
        .to raise_error(ArgumentError, /to_payload must return a hash/)
    end

    it "raises a clear ArgumentError when payload source is a non-hash value" do
      string_source = Class.new do
        def to_payload = { source: "oops" }
      end
      string_source::RECORD_KIND = "item"
      expect { described_class.from_record(string_source.new) }
        .to raise_error(ArgumentError, %r{source/member must be a hash})
    end

    it "raises a clear ArgumentError when payload idempotency_key is missing" do
      keyless_payload = Class.new do
        def to_payload
          {
            observed_at: "2026-08-14T19:00:00.000000Z",
            source: {
              service_type: "asana",
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            }
          }
        end
      end
      keyless_payload::RECORD_KIND = "item"

      expect { described_class.from_record(keyless_payload.new) }
        .to raise_error(ArgumentError, /payload idempotency_key is required/)
    end

    it "raises a clear ArgumentError when extracted service provenance is missing" do
      missing_identity = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
            observed_at: "2026-08-14T19:00:00.000000Z",
            source: { external_id: "123" }
          }
        end
      end
      missing_identity::RECORD_KIND = "item"

      expect { described_class.from_record(missing_identity.new) }
        .to raise_error(ArgumentError, /payload service_type is required/)
    end

    it "raises a clear ArgumentError when payload does not expose observed_at or started_at" do
      missing_observed_at = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
            source: {
              service_type: "asana",
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            }
          }
        end
      end
      missing_observed_at::RECORD_KIND = "item"

      expect { described_class.from_record(missing_observed_at.new) }
        .to raise_error(ArgumentError, /payload observed_at is required/)
    end

    it "raises a clear ArgumentError when payload observed_at is invalid" do
      invalid_observed_at = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
            observed_at: "2026-08-14 19:00:00",
            source: {
              service_type: "asana",
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            }
          }
        end
      end
      invalid_observed_at::RECORD_KIND = "item"

      expect { described_class.from_record(invalid_observed_at.new) }
        .to raise_error(ArgumentError, /payload observed_at is invalid/)
    end

    it "builds an entry from a Publication::ItemSnapshot" do
      snapshot = build_item_snapshot
      entry = described_class.from_record(snapshot)

      expect(entry.idempotency_key).to eq(snapshot.idempotency_key)
      expect(entry.record_kind).to eq("item")
      expect(entry.service_type).to eq("asana")
      expect(entry.service_instance).to eq("asana:workspace-12345:default")
      expect(entry.observed_at).to eq(Time.utc(2026, 8, 14, 19, 0, 0))
      expect(entry.status).to eq("pending")
    end

    it "stores JSON-serializable payload" do
      snapshot = build_item_snapshot
      entry = described_class.from_record(snapshot)
      expect { JSON.parse(entry.payload) }.not_to raise_error
    end

    it "rejects nested invalid UTF-8 before an outbox record can be built" do
      expect do
        Publication::Observation.new(
          idempotency_key: "tb:v1:obs:asana:workspace-12345:default:123:source_changed:2026-08-14T19:00:00.000000Z",
          event_type: "source_changed",
          observed_at: "2026-08-14T19:00:00.000000Z",
          item_key: "asana:workspace-12345:default:123",
          source:,
          change: { field: "title", from: (+"old title \xff").force_encoding("UTF-8"), to: "new title" }
        )
      end.to raise_error(ArgumentError, /change\.from must be valid UTF-8/)
    end

    it "raises a clear ArgumentError when source_metadata nests beyond the JSON generation limit" do
      deep_metadata = { "v" => 1 }
      150.times { deep_metadata = { "v" => deep_metadata } }
      snapshot = Publication::ItemSnapshot.new(
        idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
        item_key: "asana:workspace-12345:default:123",
        observed_at: "2026-08-14T19:00:00.000000Z",
        title: "Test task",
        status: "open",
        is_deleted: false,
        source:,
        source_metadata: deep_metadata
      )
      expect { described_class.from_record(snapshot) }
        .to raise_error(ArgumentError, /payload for .*123:snapshot.* is not serializable/)
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
        last_successful_at: "2026-08-14T19:01:00.000000Z",
        status: "success",
        items_synced: 5
      )
      entry = described_class.from_record(run_summary)

      expect(entry.record_kind).to eq("sync_run")
      expect(entry.service_type).to eq("asana")
      expect(entry.service_instance).to eq("asana:workspace-12345:default")
      expect(entry.observed_at).to eq(Time.utc(2026, 8, 14, 19, 0, 0))
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
      expect(entry.observed_at).to eq(Time.utc(2026, 8, 14, 19, 21, 0))
    end

    it "extracts service_type and service_instance from source for observation records" do
      observation = Publication::Observation.new(
        idempotency_key: "tb:v1:obs:asana:workspace-12345:default:123:source_changed:2026-08-14T19:00:00.000000Z",
        event_type: "source_changed",
        observed_at: "2026-08-14T19:00:00.000000Z",
        item_key: "asana:workspace-12345:default:123",
        source:
      )
      entry = described_class.from_record(observation)

      expect(entry.record_kind).to eq("observation")
      expect(entry.service_type).to eq("asana")
      expect(entry.service_instance).to eq("asana:workspace-12345:default")
      expect(entry.observed_at).to be_present
    end

    it "extracts identity and observed_at from string-keyed payload hashes" do
      string_keyed_snapshot = Class.new do
        def to_payload
          {
            "contract_version" => 1,
            "idempotency_key" => "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
            "observed_at" => "2026-08-14T19:00:00.000000Z",
            "source" => {
              "service_type" => "asana",
              "service_instance" => "asana:workspace-12345:default",
              "external_id" => "123"
            }
          }
        end
      end
      string_keyed_snapshot.const_set(:RECORD_KIND, "item")

      entry = described_class.from_record(string_keyed_snapshot.new)

      expect(entry.idempotency_key).to eq("tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z")
      expect(entry.service_type).to eq("asana")
      expect(entry.service_instance).to eq("asana:workspace-12345:default")
      expect(entry.observed_at).to eq(Time.utc(2026, 8, 14, 19, 0, 0))
    end
  end

  describe "scopes" do
    before do
      described_class.create!(valid_entry_attrs.merge(idempotency_key: "key-pending", status: "pending"))
      described_class.create!(valid_entry_attrs.merge(idempotency_key: "key-delivering", status: "delivering"))
      described_class.create!(valid_entry_attrs.merge(idempotency_key: "key-delivered", status: "delivered"))
      described_class.create!(valid_entry_attrs.merge(idempotency_key: "key-failed", status: "failed", retry_count: 2))
      described_class.create!(valid_entry_attrs.merge(idempotency_key: "key-terminal", status: "terminal", retry_count: 10))
    end

    it "pending returns only pending rows" do
      expect(described_class.pending.map(&:idempotency_key)).to eq(["key-pending"])
    end

    it "delivering returns only delivering rows" do
      expect(described_class.delivering.map(&:idempotency_key)).to eq(["key-delivering"])
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

    it "clears a stale error message from an earlier failed attempt" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_failed!(message: "network timeout")
      entry.mark_delivered!
      expect(entry.reload.error_message).to be_nil
    end

    it "clears a stale failed_at from an earlier failed attempt" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_failed!(message: "network timeout")
      entry.mark_delivered!
      expect(entry.reload.failed_at).to be_nil
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

    it "scrubs malformed bytes from the message so recording a failure cannot fail" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_failed!(message: (+"boom \xff").force_encoding("UTF-8"))
      expect(entry.reload.error_message).to be_present
      expect(entry.error_message.valid_encoding?).to be true
    end

    it "clears a stale delivered_at from an earlier successful attempt" do
      entry = described_class.create!(valid_entry_attrs.merge(status: "delivered", delivered_at: Time.current))
      entry.mark_failed!(message: "network timeout")
      expect(entry.reload.delivered_at).to be_nil
    end
  end

  describe "#mark_terminal!" do
    it "sets status to terminal and records failed_at without incrementing retry_count" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_terminal!(message: "validation_error: source.service_instance is required")
      expect(entry.reload.status).to eq("terminal")
      expect(entry.failed_at).to be_present
      expect(entry.retry_count).to eq(0)
      expect(entry.error_message).to include("validation_error")
    end

    it "excludes the row from future publish attempts" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_terminal!(message: "non-retryable rejection")
      expect(described_class.publishable.map(&:idempotency_key)).not_to include(entry.idempotency_key)
    end

    it "truncates long error messages" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_terminal!(message: "x" * 2000)
      expect(entry.reload.error_message.length).to eq(1000)
    end

    it "clears a stale delivered_at from an earlier successful attempt" do
      entry = described_class.create!(valid_entry_attrs.merge(status: "delivered", delivered_at: Time.current))
      entry.mark_terminal!(message: "non-retryable rejection")
      expect(entry.reload.delivered_at).to be_nil
    end
  end

  describe "#mark_replayed!" do
    it "sets status to delivered" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_replayed!
      expect(entry.reload.status).to eq("delivered")
    end

    it "clears a stale error message from an earlier failed attempt" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_failed!(message: "network timeout")
      entry.mark_replayed!
      expect(entry.reload.error_message).to be_nil
    end

    it "clears a stale failed_at from an earlier failed attempt" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_failed!(message: "network timeout")
      entry.mark_replayed!
      expect(entry.reload.failed_at).to be_nil
    end
  end

  describe "#parsed_payload" do
    it "returns symbolized hash from payload JSON" do
      entry = described_class.new(valid_entry_attrs)
      expect(entry.parsed_payload).to be_a(Hash)
      expect(entry.parsed_payload[:contract_version]).to eq(1)
    end

    it "re-parses when payload changes in memory" do
      entry = described_class.new(valid_entry_attrs)
      expect(entry.parsed_payload[:idempotency_key]).to eq(valid_entry_attrs[:idempotency_key])

      entry.payload = {
        contract_version: 1,
        idempotency_key: "tb:v1:item:asana:default:2:snapshot:2026-08-14T19:00:00.000000Z"
      }.to_json

      expect(entry.parsed_payload[:idempotency_key]).to eq(
        "tb:v1:item:asana:default:2:snapshot:2026-08-14T19:00:00.000000Z"
      )
    end
  end
end
