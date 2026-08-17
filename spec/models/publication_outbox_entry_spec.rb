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

  def valid_entry_attrs(idempotency_key: "tb:v1:item:asana:default:1:snapshot:2026-08-14T19:00:00.000000Z")
    {
      idempotency_key:,
      record_kind: "item",
      payload: { contract_version: 1, idempotency_key: }.to_json,
      service_type: "asana",
      service_instance: "asana:workspace-12345:default",
      observed_at: Time.zone.parse("2026-08-14T19:00:00Z")
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

    it "returns validation errors instead of raising when a required string field is not a string" do
      entry = described_class.new(valid_entry_attrs)
      entry.define_singleton_method(:service_type) { 42 }

      expect(entry).not_to be_valid
      expect(entry.errors[:service_type]).to include("must be a string")
    end

    it "returns validation errors instead of raising when an optional string field is not a string" do
      entry = described_class.new(valid_entry_attrs)
      entry.define_singleton_method(:error_message) { 42 }

      expect(entry).not_to be_valid
      expect(entry.errors[:error_message]).to include("must be a string")
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

    it "rejects a payload with a missing contract_version" do
      entry = described_class.new(
        valid_entry_attrs.merge(
          payload: { idempotency_key: valid_entry_attrs[:idempotency_key] }.to_json
        )
      )
      expect(entry).not_to be_valid
      expect(entry.errors[:payload]).to include("contract_version must be 1")
    end

    it "rejects a payload with a non-integer contract_version" do
      entry = described_class.new(
        valid_entry_attrs.merge(
          payload: { contract_version: 1.0, idempotency_key: valid_entry_attrs[:idempotency_key] }.to_json
        )
      )
      expect(entry).not_to be_valid
      expect(entry.errors[:payload]).to include("contract_version must be 1")
    end

    it "rejects a payload with the wrong contract_version" do
      entry = described_class.new(
        valid_entry_attrs.merge(
          payload: { contract_version: 2, idempotency_key: valid_entry_attrs[:idempotency_key] }.to_json
        )
      )
      expect(entry).not_to be_valid
      expect(entry.errors[:payload]).to include("contract_version must be 1")
    end

    it "rejects a payload whose idempotency_key disagrees with the outbox row" do
      entry = described_class.new(
        valid_entry_attrs.merge(
          payload: { contract_version: 1, idempotency_key: "tb:v1:item:asana:default:999:snapshot:2026-08-14T19:00:00.000000Z" }.to_json
        )
      )

      expect(entry).not_to be_valid
      expect(entry.errors[:payload]).to include("idempotency_key must match the outbox row")
    end

    it "rejects a payload that is not valid UTF-8 even though JSON.parse accepts it" do
      payload = (+"{\"idempotency_key\": \"k\", \"title\": \"milk \xff\"}").force_encoding("UTF-8")
      entry = described_class.new(valid_entry_attrs.merge(payload: payload))
      expect(entry).not_to be_valid
      expect(entry.errors[:payload]).to include("must be valid UTF-8")
    end

    it "rejects a payload that cannot be serialized as UTF-8 even when valid_encoding? is true" do
      payload = "{\"idempotency_key\":\"k\",\"title\":\"\xFF\"}".dup.force_encoding("ASCII-8BIT")
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

    it "requires extracted service provenance to be present" do
      entry = described_class.new(valid_entry_attrs.merge(service_type: nil, service_instance: ""))
      expect(entry).not_to be_valid
      expect(entry.errors[:service_type]).to be_present
      expect(entry.errors[:service_instance]).to be_present
    end

    it "requires observed_at to be present" do
      entry = described_class.new(valid_entry_attrs.merge(observed_at: nil))
      expect(entry).not_to be_valid
      expect(entry.errors[:observed_at]).to be_present
    end

    it "rejects an observed_at without a timezone designator" do
      entry = described_class.new(valid_entry_attrs.merge(observed_at: "2026-08-14T19:00:00"))
      expect(entry).not_to be_valid
      expect(entry.errors[:observed_at]).to include(/missing timezone/)
    end

    it "returns validation errors instead of raising when observed_at carries invalid UTF-8" do
      entry = described_class.new(valid_entry_attrs.merge(observed_at: (+"2026-08-14T19:00:00Z\xff").force_encoding("UTF-8")))

      expect(entry).not_to be_valid
      expect(entry.errors[:observed_at]).to include("observed_at must be valid UTF-8")
    end

    it "returns validation errors instead of raising when idempotency_key carries invalid UTF-8" do
      entry = described_class.new(valid_entry_attrs.merge(idempotency_key: (+"tb:v1:\xff").force_encoding("UTF-8")))
      expect(entry).not_to be_valid
      expect(entry.errors[:idempotency_key]).to include("must be valid UTF-8")
    end

    it "returns validation errors when a required string cannot be serialized as UTF-8" do
      entry = described_class.new(valid_entry_attrs.merge(idempotency_key: "tb:v1:item:\xFF".dup.force_encoding("ASCII-8BIT")))

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

  describe "schema" do
    it "stores extracted provenance as required columns" do
      expect(described_class.columns_hash["service_type"].null).to be(false)
      expect(described_class.columns_hash["service_instance"].null).to be(false)
      expect(described_class.columns_hash["observed_at"].null).to be(false)
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
        .to raise_error(ArgumentError, /payload source must be a hash when present/)
    end

    it "raises a clear ArgumentError when an item payload omits its required source hash" do
      source_less_item = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
            observed_at: "2026-08-14T19:00:00.000000Z",
            service_type: "asana",
            service_instance: "asana:workspace-12345:default"
          }
        end
      end
      source_less_item::RECORD_KIND = "item"

      expect { described_class.from_record(source_less_item.new) }
        .to raise_error(ArgumentError, /payload source is required/)
    end

    it "does not fall back from a present nil source to member provenance" do
      mixed_identity = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
            observed_at: "2026-08-14T19:00:00.000000Z",
            source: nil,
            member: {
              service_type: "github",
              service_instance: "github:repo-1:default",
              external_id: "42",
              item_key: "github:repo-1:default:42"
            }
          }
        end
      end
      mixed_identity::RECORD_KIND = "item"

      expect { described_class.from_record(mixed_identity.new) }
        .to raise_error(ArgumentError, /payload source must be a hash when present/)
    end

    it "raises a clear ArgumentError when a mapping payload omits its required member hash" do
      member_less_mapping = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:map:sync_collection:84:membership:asana:workspace-12345:default:123:2026-08-14T19:00:00.000000Z",
            observed_at: "2026-08-14T19:00:00.000000Z",
            service_type: "asana",
            service_instance: "asana:workspace-12345:default"
          }
        end
      end
      member_less_mapping::RECORD_KIND = "mapping"

      expect { described_class.from_record(member_less_mapping.new) }
        .to raise_error(ArgumentError, /payload member is required/)
    end

    it "raises a clear ArgumentError when a mapping payload omits its required sync_collection hash" do
      sync_collection_less_mapping = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:map:sync_collection:84:membership:asana:workspace-12345:default:123:2026-08-14T19:00:00.000000Z",
            observed_at: "2026-08-14T19:00:00.000000Z",
            member: {
              item_key: "asana:workspace-12345:default:123",
              service_type: "asana",
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            }
          }
        end
      end
      sync_collection_less_mapping::RECORD_KIND = "mapping"

      expect { described_class.from_record(sync_collection_less_mapping.new) }
        .to raise_error(ArgumentError, /payload sync_collection is required/)
    end

    it "raises a clear ArgumentError when mapping sync_collection_id is missing" do
      missing_sync_collection_id = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:map:sync_collection:84:membership:asana:workspace-12345:default:123:2026-08-14T19:00:00.000000Z",
            observed_at: "2026-08-14T19:00:00.000000Z",
            sync_collection: {},
            member: {
              item_key: "asana:workspace-12345:default:123",
              service_type: "asana",
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            }
          }
        end
      end
      missing_sync_collection_id::RECORD_KIND = "mapping"

      expect { described_class.from_record(missing_sync_collection_id.new) }
        .to raise_error(ArgumentError, /payload sync_collection\.sync_collection_id is required/)
    end

    it "raises a clear ArgumentError when mapping sync_collection_id has the wrong type" do
      invalid_sync_collection_id = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:map:sync_collection:84:membership:asana:workspace-12345:default:123:2026-08-14T19:00:00.000000Z",
            observed_at: "2026-08-14T19:00:00.000000Z",
            sync_collection: { sync_collection_id: { bad: true } },
            member: {
              item_key: "asana:workspace-12345:default:123",
              service_type: "asana",
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            }
          }
        end
      end
      invalid_sync_collection_id::RECORD_KIND = "mapping"

      expect { described_class.from_record(invalid_sync_collection_id.new) }
        .to raise_error(ArgumentError, /payload sync_collection\.sync_collection_id must be a string or integer/)
    end

    it "raises a clear ArgumentError when payload idempotency_key is missing" do
      keyless_payload = Class.new do
        def to_payload
          {
            contract_version: 1,
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

    it "raises a clear ArgumentError when payload contract_version is missing" do
      missing_version = Class.new do
        def to_payload
          {
            idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
            observed_at: "2026-08-14T19:00:00.000000Z",
            source: {
              service_type: "asana",
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            }
          }
        end
      end
      missing_version::RECORD_KIND = "item"

      expect { described_class.from_record(missing_version.new) }
        .to raise_error(ArgumentError, /payload contract_version must be 1/)
    end

    it "raises a clear ArgumentError when payload contract_version is not the canonical integer" do
      wrong_version = Class.new do
        def to_payload
          {
            contract_version: 1.0,
            idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
            observed_at: "2026-08-14T19:00:00.000000Z",
            source: {
              service_type: "asana",
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            }
          }
        end
      end
      wrong_version::RECORD_KIND = "item"

      expect { described_class.from_record(wrong_version.new) }
        .to raise_error(ArgumentError, /payload contract_version must be 1/)
    end

    it "raises a clear ArgumentError when payload idempotency_key carries invalid UTF-8" do
      invalid_key = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: (+"tb:v1:item:\xff").force_encoding("UTF-8"),
            observed_at: "2026-08-14T19:00:00.000000Z",
            source: {
              service_type: "asana",
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            }
          }
        end
      end
      invalid_key::RECORD_KIND = "item"

      expect { described_class.from_record(invalid_key.new) }
        .to raise_error(ArgumentError, /payload idempotency_key must be valid UTF-8/)
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
        .to raise_error(ArgumentError, /payload source\.service_type is required/)
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

    it "raises a clear ArgumentError when payload service_type carries invalid UTF-8" do
      invalid_service_type = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
            observed_at: "2026-08-14T19:00:00.000000Z",
            source: {
              service_type: (+"asana \xff").force_encoding("UTF-8"),
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            }
          }
        end
      end
      invalid_service_type::RECORD_KIND = "item"

      expect { described_class.from_record(invalid_service_type.new) }
        .to raise_error(ArgumentError, /payload source\.service_type must be valid UTF-8/)
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

    it "does not mask a blank observed_at by falling back to started_at" do
      blank_observed_at = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
            observed_at: "",
            started_at: "2026-08-14T19:00:00.000000Z",
            source: {
              service_type: "asana",
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            }
          }
        end
      end
      blank_observed_at::RECORD_KIND = "item"

      expect { described_class.from_record(blank_observed_at.new) }
        .to raise_error(ArgumentError, /payload observed_at is required/)
    end

    it "raises a clear ArgumentError when payload observed_at carries invalid UTF-8" do
      invalid_observed_at = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
            observed_at: (+"2026-08-14T19:00:00.000000Z\xff").force_encoding("UTF-8"),
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
        .to raise_error(ArgumentError, /payload observed_at must be valid UTF-8/)
    end

    it "does not mask a blank source service_type with a root fallback" do
      blank_source_service_type = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
            observed_at: "2026-08-14T19:00:00.000000Z",
            service_type: "root-service",
            source: {
              service_type: "",
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            }
          }
        end
      end
      blank_source_service_type::RECORD_KIND = "item"

      expect { described_class.from_record(blank_source_service_type.new) }
        .to raise_error(ArgumentError, /payload source\.service_type is required/)
    end

    it "does not mask a missing source service_type with a root fallback" do
      missing_source_service_type = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
            observed_at: "2026-08-14T19:00:00.000000Z",
            service_type: "root-service",
            source: {
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            }
          }
        end
      end
      missing_source_service_type::RECORD_KIND = "item"

      expect { described_class.from_record(missing_source_service_type.new) }
        .to raise_error(ArgumentError, /payload source\.service_type is required/)
    end

    it "does not mask a missing mapping member item_key with a root fallback" do
      missing_member_item_key = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:map:sync_collection:84:membership:github:repo-1:issue-42:2026-08-14T19:21:00.000000Z",
            observed_at: "2026-08-14T19:21:00.000000Z",
            item_key: "root:item:key",
            member: {
              service_type: "github",
              service_instance: "github:repo-1",
              external_id: "issue-42"
            }
          }
        end
      end
      missing_member_item_key::RECORD_KIND = "mapping"

      expect { described_class.from_record(missing_member_item_key.new) }
        .to raise_error(ArgumentError, /payload member\.item_key is required/)
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

    it "preserves observed_at microseconds when the entry is persisted" do
      snapshot = Publication::ItemSnapshot.new(
        idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.123456Z",
        item_key: "asana:workspace-12345:default:123",
        observed_at: "2026-08-14T19:00:00.123456Z",
        title: "Test task",
        status: "open",
        is_deleted: false,
        source:
      )

      entry = described_class.from_record(snapshot)
      entry.save!

      expect(entry.reload.observed_at).to eq(Time.utc(2026, 8, 14, 19, 0, 0, 123_456))
    end

    it "stores JSON-serializable payload" do
      snapshot = build_item_snapshot
      entry = described_class.from_record(snapshot)
      expect { JSON.parse(entry.payload) }.not_to raise_error
    end

    it "strips record-level published_at before persisting the canonical payload" do
      observation = Publication::Observation.new(
        idempotency_key: "tb:v1:obs:asana:workspace-12345:default:123:snapshot_seen:2026-08-14T19:00:00.000000Z",
        event_type: "snapshot_seen",
        observed_at: "2026-08-14T19:00:00.000000Z",
        published_at: "2026-08-14T19:05:00.000000Z",
        item_key: "asana:workspace-12345:default:123",
        source:
      )

      entry = described_class.from_record(observation)

      expect(entry.parsed_payload).not_to have_key(:published_at)
    end

    it "strips string-keyed published_at before persisting the canonical payload" do
      string_keyed_observation = Class.new do
        def to_payload
          {
            "contract_version" => 1,
            "idempotency_key" => "tb:v1:obs:asana:workspace-12345:default:123:snapshot_seen:2026-08-14T19:00:00.000000Z",
            "event_type" => "snapshot_seen",
            "observed_at" => "2026-08-14T19:00:00.000000Z",
            "published_at" => "2026-08-14T19:05:00.000000Z",
            "item_key" => "asana:workspace-12345:default:123",
            "source" => {
              "service_type" => "asana",
              "service_instance" => "asana:workspace-12345:default",
              "external_id" => "123"
            }
          }
        end
      end
      string_keyed_observation.const_set(:RECORD_KIND, "observation")

      entry = described_class.from_record(string_keyed_observation.new)

      expect(entry.parsed_payload).not_to have_key(:published_at)
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

    it "does not let a stray source section override root provenance for sync_run records" do
      sync_run_with_source = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:sync_run:asana:workspace-12345:default:run-1",
            service_type: "asana",
            service_instance: "asana:workspace-12345:default",
            started_at: "2026-08-14T19:00:00.000000Z",
            status: "success",
            source: {
              service_type: "github",
              service_instance: "github:repo-1",
              external_id: "issue-42"
            }
          }
        end
      end
      sync_run_with_source::RECORD_KIND = "sync_run"

      entry = described_class.from_record(sync_run_with_source.new)

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
      expect(entry.observed_at).to eq(Time.utc(2026, 8, 14, 19, 21, 0))
    end

    it "does not let a stray source section override member provenance for mapping records" do
      mapping_with_source = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:map:sync_collection:84:membership:github:repo-1:issue-42:2026-08-14T19:21:00.000000Z",
            observed_at: "2026-08-14T19:21:00.000000Z",
            sync_collection: { sync_collection_id: 84 },
            source: {
              service_type: "asana",
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            },
            member: {
              item_key: "github:repo-1:issue-42",
              service_type: "github",
              service_instance: "github:repo-1",
              external_id: "issue-42"
            }
          }
        end
      end
      mapping_with_source::RECORD_KIND = "mapping"

      entry = described_class.from_record(mapping_with_source.new)

      expect(entry.service_type).to eq("github")
      expect(entry.service_instance).to eq("github:repo-1")
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

    it "canonicalizes observed_at before storing outbox metadata" do
      noncanonical_snapshot = Class.new do
        def to_payload
          {
            contract_version: 1,
            idempotency_key: "tb:v1:item:asana:workspace-12345:default:123:snapshot:2026-08-14T19:00:00.000000Z",
            observed_at: "2026-08-14T12:00:00-07:00",
            source: {
              service_type: "asana",
              service_instance: "asana:workspace-12345:default",
              external_id: "123"
            }
          }
        end
      end
      noncanonical_snapshot.const_set(:RECORD_KIND, "item")

      entry = described_class.from_record(noncanonical_snapshot.new)

      expect(entry.observed_at).to eq(Time.utc(2026, 8, 14, 19, 0, 0))
    end
  end

  describe "scopes" do
    before do
      described_class.create!(valid_entry_attrs(idempotency_key: "key-pending").merge(status: "pending"))
      described_class.create!(valid_entry_attrs(idempotency_key: "key-delivering").merge(status: "delivering"))
      described_class.create!(valid_entry_attrs(idempotency_key: "key-delivered").merge(status: "delivered"))
      described_class.create!(valid_entry_attrs(idempotency_key: "key-failed").merge(status: "failed", retry_count: 2))
      described_class.create!(valid_entry_attrs(idempotency_key: "key-terminal").merge(status: "terminal", retry_count: 10))
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

    it "publishable skips failed rows whose retry backoff has not elapsed yet" do
      described_class.delete_all

      ready = described_class.create!(
        valid_entry_attrs(idempotency_key: "key-ready-failed").merge(
          status: "failed",
          retry_count: 1,
          next_attempt_at: 1.minute.ago
        )
      )
      waiting = described_class.create!(
        valid_entry_attrs(idempotency_key: "key-waiting-failed").merge(
          status: "failed",
          retry_count: 1,
          next_attempt_at: 1.minute.from_now
        )
      )

      expect(described_class.publishable).to include(ready)
      expect(described_class.publishable).not_to include(waiting)
    end

    it "stale_delivering returns only abandoned claims older than the reclaim cutoff" do
      described_class.delete_all

      stale = described_class.create!(
        valid_entry_attrs(idempotency_key: "key-stale-delivering").merge(
          status: "delivering",
          updated_at: described_class.stale_delivery_cutoff - 1.second
        )
      )
      fresh = described_class.create!(
        valid_entry_attrs(idempotency_key: "key-fresh-delivering").merge(
          status: "delivering",
          updated_at: described_class.stale_delivery_cutoff + 1.second
        )
      )

      expect(described_class.stale_delivering.map(&:idempotency_key)).to eq([stale.idempotency_key])
      expect(described_class.stale_delivering).not_to include(fresh)
    end

    it "publishable reclaims stale delivering rows so abandoned claims self-heal" do
      described_class.delete_all

      stale = described_class.create!(
        valid_entry_attrs(idempotency_key: "key-stale-delivering").merge(
          status: "delivering",
          observed_at: Time.utc(2026, 8, 14, 18, 58, 0),
          updated_at: described_class.stale_delivery_cutoff - 1.second
        )
      )
      fresh = described_class.create!(
        valid_entry_attrs(idempotency_key: "key-fresh-delivering").merge(
          status: "delivering",
          observed_at: Time.utc(2026, 8, 14, 18, 57, 0),
          updated_at: described_class.stale_delivery_cutoff + 1.second
        )
      )

      expect(described_class.publishable.map(&:idempotency_key)).to include(stale.idempotency_key)
      expect(described_class.publishable).not_to include(fresh)
    end

    it "publishable orders rows by observed_at before created_at" do
      described_class.delete_all

      later_created_earlier_observed = described_class.create!(
        valid_entry_attrs(idempotency_key: "key-earlier-observed").merge(
          status: "failed",
          retry_count: 1,
          observed_at: Time.utc(2026, 8, 14, 18, 59, 0),
          created_at: Time.utc(2026, 8, 15, 12, 0, 5),
          updated_at: Time.utc(2026, 8, 15, 12, 0, 5)
        )
      )
      earlier_created_later_observed = described_class.create!(
        valid_entry_attrs(idempotency_key: "key-later-observed").merge(
          status: "pending",
          observed_at: Time.utc(2026, 8, 14, 19, 1, 0),
          created_at: Time.utc(2026, 8, 15, 12, 0, 0),
          updated_at: Time.utc(2026, 8, 15, 12, 0, 0)
        )
      )

      expect(described_class.publishable.map(&:idempotency_key)).to eq(
        [later_created_earlier_observed.idempotency_key, earlier_created_later_observed.idempotency_key]
      )
    end

    it "publishable breaks observed_at ties by id for stable batch order" do
      described_class.delete_all
      shared_created_at = Time.utc(2026, 8, 15, 12, 0, 0)
      shared_observed_at = Time.utc(2026, 8, 14, 19, 0, 0)

      second = described_class.create!(
        valid_entry_attrs(idempotency_key: "key-second").merge(
          status: "failed",
          retry_count: 1,
          observed_at: shared_observed_at,
          created_at: shared_created_at,
          updated_at: shared_created_at
        )
      )
      first = described_class.create!(
        valid_entry_attrs(idempotency_key: "key-first").merge(
          status: "pending",
          observed_at: shared_observed_at,
          created_at: shared_created_at,
          updated_at: shared_created_at
        )
      )

      expect(described_class.publishable.pluck(:id)).to eq([second.id, first.id].sort)
      expect(described_class.publishable.map(&:idempotency_key)).to eq([second, first].sort_by(&:id).map(&:idempotency_key))
    end
  end

  describe "#mark_delivering!" do
    it "sets status to delivering" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_delivering!
      expect(entry.reload.status).to eq("delivering")
    end

    it "excludes the row from publishable once claimed" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_delivering!
      expect(described_class.publishable.map(&:idempotency_key)).not_to include(entry.idempotency_key)
    end

    it "rejects attempts to claim a terminal row" do
      entry = described_class.create!(valid_entry_attrs.merge(status: "terminal", failed_at: Time.current))

      expect { entry.mark_delivering! }
        .to raise_error(ArgumentError, /mark_delivering! cannot transition a terminal outbox row/)
    end

    it "rejects attempts to claim a delivered row" do
      entry = described_class.create!(valid_entry_attrs.merge(status: "delivered", delivered_at: Time.current))

      expect { entry.mark_delivering! }
        .to raise_error(ArgumentError, /mark_delivering! cannot transition a delivered outbox row/)
    end

    it "raises a consistent persistence error for an unsaved row" do
      entry = described_class.new(valid_entry_attrs)

      expect { entry.mark_delivering! }
        .to raise_error(ActiveRecord::RecordNotSaved, /mark_delivering! requires a persisted outbox row/)
    end

    it "clears a stale error message from an earlier failed attempt" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_failed!(message: "network timeout")

      entry.mark_delivering!

      expect(entry.reload.error_message).to be_nil
    end

    it "clears a stale failed_at from an earlier failed attempt" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_failed!(message: "network timeout")

      entry.mark_delivering!

      expect(entry.reload.failed_at).to be_nil
    end

    it "rejects attempts to claim a fresh delivering row" do
      entry = described_class.create!(valid_entry_attrs.merge(status: "delivering"))

      expect { entry.mark_delivering! }
        .to raise_error(ArgumentError, /mark_delivering! cannot transition a fresh delivering outbox row/)
    end

    it "allows reclaiming a stale delivering row" do
      entry = described_class.create!(
        valid_entry_attrs.merge(
          status: "delivering",
          updated_at: described_class.stale_delivery_cutoff - 1.second
        )
      )

      expect { entry.mark_delivering! }.not_to raise_error
      expect(entry.reload.status).to eq("delivering")
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

    it "rejects attempts to deliver a terminal row" do
      entry = described_class.create!(valid_entry_attrs.merge(status: "terminal", failed_at: Time.current))

      expect { entry.mark_delivered! }
        .to raise_error(ArgumentError, /mark_delivered! cannot transition a terminal outbox row/)
    end

    it "rejects attempts to deliver a delivered row" do
      entry = described_class.create!(valid_entry_attrs.merge(status: "delivered", delivered_at: Time.current))

      expect { entry.mark_delivered! }
        .to raise_error(ArgumentError, /mark_delivered! cannot transition a delivered outbox row/)
    end

    it "rejects a stale instance after another worker delivers the row" do
      entry = described_class.create!(valid_entry_attrs)
      stale_entry = described_class.find(entry.id)

      entry.mark_delivered!

      expect { stale_entry.mark_delivered! }
        .to raise_error(ArgumentError, /mark_delivered! cannot transition a delivered outbox row/)
    end

    it "raises a consistent persistence error for an unsaved row" do
      entry = described_class.new(valid_entry_attrs)

      expect { entry.mark_delivered! }
        .to raise_error(ActiveRecord::RecordNotSaved, /mark_delivered! requires a persisted outbox row/)
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

    it "schedules the next retry attempt with exponential backoff and jitter" do
      allow(described_class).to receive(:retry_jitter_seconds).and_return(7)
      entry = described_class.create!(valid_entry_attrs)

      entry.mark_failed!(message: "network timeout")

      failed_at = entry.reload.failed_at
      expect(entry.next_attempt_at).to eq(failed_at + 67.seconds)
    end

    it "keeps a failed row out of publishable until next_attempt_at arrives" do
      allow(described_class).to receive(:retry_jitter_seconds).and_return(0)
      entry = described_class.create!(valid_entry_attrs)

      entry.mark_failed!(message: "network timeout")

      expect(described_class.publishable).not_to include(entry)

      entry.update!(next_attempt_at: 1.second.ago)

      expect(described_class.publishable).to include(entry.reload)
    end

    it "transitions to terminal when retry_count reaches MAX_RETRIES" do
      entry = described_class.create!(valid_entry_attrs.merge(retry_count: described_class::MAX_RETRIES - 1))
      entry.mark_failed!(message: "permanent error")
      expect(entry.reload.status).to eq("terminal")
      expect(entry.next_attempt_at).to be_nil
    end

    it "scrubs malformed bytes from the message so recording a failure cannot fail" do
      entry = described_class.create!(valid_entry_attrs)
      entry.mark_failed!(message: (+"boom \xff").force_encoding("UTF-8"))
      expect(entry.reload.error_message).to be_present
      expect(entry.error_message.valid_encoding?).to be true
    end

    it "rejects attempts to fail a delivered row" do
      entry = described_class.create!(valid_entry_attrs.merge(status: "delivered", delivered_at: Time.current))

      expect { entry.mark_failed!(message: "network timeout") }
        .to raise_error(ArgumentError, /mark_failed! cannot transition a delivered outbox row/)
    end

    it "rejects attempts to fail a terminal row" do
      entry = described_class.create!(valid_entry_attrs.merge(status: "terminal", failed_at: Time.current))

      expect { entry.mark_failed!(message: "network timeout") }
        .to raise_error(ArgumentError, /mark_failed! cannot transition a terminal outbox row/)
    end

    it "rejects a stale instance after another worker delivers the row" do
      entry = described_class.create!(valid_entry_attrs)
      stale_entry = described_class.find(entry.id)

      entry.mark_delivered!

      expect { stale_entry.mark_failed!(message: "network timeout") }
        .to raise_error(ArgumentError, /mark_failed! cannot transition a delivered outbox row/)
    end

    it "raises a consistent persistence error for an unsaved row" do
      entry = described_class.new(valid_entry_attrs)

      expect { entry.mark_failed!(message: "network timeout") }
        .to raise_error(ActiveRecord::RecordNotSaved, /mark_failed! requires a persisted outbox row/)
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

    it "rejects attempts to terminal a delivered row" do
      entry = described_class.create!(valid_entry_attrs.merge(status: "delivered", delivered_at: Time.current))

      expect { entry.mark_terminal!(message: "non-retryable rejection") }
        .to raise_error(ArgumentError, /mark_terminal! cannot transition a delivered outbox row/)
    end

    it "rejects attempts to terminal a terminal row" do
      entry = described_class.create!(valid_entry_attrs.merge(status: "terminal", failed_at: Time.current))

      expect { entry.mark_terminal!(message: "non-retryable rejection") }
        .to raise_error(ArgumentError, /mark_terminal! cannot transition a terminal outbox row/)
    end

    it "rejects a stale instance after another worker terminals the row" do
      entry = described_class.create!(valid_entry_attrs)
      stale_entry = described_class.find(entry.id)

      entry.mark_terminal!(message: "non-retryable rejection")

      expect { stale_entry.mark_terminal!(message: "non-retryable rejection") }
        .to raise_error(ArgumentError, /mark_terminal! cannot transition a terminal outbox row/)
    end

    it "raises a consistent persistence error for an unsaved row" do
      entry = described_class.new(valid_entry_attrs)

      expect { entry.mark_terminal!(message: "non-retryable rejection") }
        .to raise_error(ActiveRecord::RecordNotSaved, /mark_terminal! requires a persisted outbox row/)
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

    it "rejects attempts to replay a terminal row" do
      entry = described_class.create!(valid_entry_attrs.merge(status: "terminal", failed_at: Time.current))

      expect { entry.mark_replayed! }
        .to raise_error(ArgumentError, /mark_replayed! cannot transition a terminal outbox row/)
    end

    it "rejects attempts to replay a delivered row" do
      entry = described_class.create!(valid_entry_attrs.merge(status: "delivered", delivered_at: Time.current))

      expect { entry.mark_replayed! }
        .to raise_error(ArgumentError, /mark_replayed! cannot transition a delivered outbox row/)
    end

    it "rejects a stale instance after another worker delivers the row" do
      entry = described_class.create!(valid_entry_attrs)
      stale_entry = described_class.find(entry.id)

      entry.mark_delivered!

      expect { stale_entry.mark_replayed! }
        .to raise_error(ArgumentError, /mark_replayed! cannot transition a delivered outbox row/)
    end

    it "raises a consistent persistence error for an unsaved row" do
      entry = described_class.new(valid_entry_attrs)

      expect { entry.mark_replayed! }
        .to raise_error(ActiveRecord::RecordNotSaved, /mark_replayed! requires a persisted outbox row/)
    end
  end

  describe "#parsed_payload" do
    it "returns symbolized hash from payload JSON" do
      entry = described_class.new(valid_entry_attrs)
      expect(entry.parsed_payload).to be_a(Hash)
      expect(entry.parsed_payload[:contract_version]).to eq(1)
    end

    it "returns an immutable cached payload" do
      entry = described_class.new(
        valid_entry_attrs.merge(
          payload: {
            contract_version: 1,
            idempotency_key: valid_entry_attrs[:idempotency_key],
            source: { service_type: "asana" }
          }.to_json
        )
      )

      expect { entry.parsed_payload[:source][:service_type] = "github" }.to raise_error(FrozenError)
      expect(entry.parsed_payload.dig(:source, :service_type)).to eq("asana")
    end

    it "raises a clear TypeError when payload is not a string" do
      entry = described_class.new(valid_entry_attrs)
      entry.define_singleton_method(:payload) { nil }

      expect { entry.parsed_payload }.to raise_error(TypeError, "payload must be a string")
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

    it "re-parses when the payload string is mutated in place" do
      entry = described_class.new(valid_entry_attrs)
      expect(entry.parsed_payload[:idempotency_key]).to eq(valid_entry_attrs[:idempotency_key])

      entry.payload.replace(
        {
          contract_version: 1,
          idempotency_key: "tb:v1:item:asana:default:3:snapshot:2026-08-14T19:00:00.000000Z"
        }.to_json
      )

      expect(entry.parsed_payload[:idempotency_key]).to eq(
        "tb:v1:item:asana:default:3:snapshot:2026-08-14T19:00:00.000000Z"
      )
    end

    it "does not cache a failed parse over the previous payload" do
      entry = described_class.new(valid_entry_attrs)
      expect(entry.parsed_payload[:idempotency_key]).to eq(valid_entry_attrs[:idempotency_key])

      entry.payload = "{"
      expect { entry.parsed_payload }.to raise_error(JSON::ParserError)
      expect { entry.parsed_payload }.to raise_error(JSON::ParserError)

      entry.payload = {
        contract_version: 1,
        idempotency_key: "tb:v1:item:asana:default:4:snapshot:2026-08-14T19:00:00.000000Z"
      }.to_json

      expect(entry.parsed_payload[:idempotency_key]).to eq(
        "tb:v1:item:asana:default:4:snapshot:2026-08-14T19:00:00.000000Z"
      )
    end
  end

  describe "#parsed_payload" do
    it "returns a deeply frozen payload hash" do
      entry = described_class.new(
        valid_entry_attrs.merge(
          payload: {
            contract_version: 1,
            idempotency_key: valid_entry_attrs[:idempotency_key],
            source: { service_type: "asana" },
            tags: ["ops"]
          }.to_json
        )
      )

      parsed = entry.parsed_payload

      expect(parsed).to be_frozen
      expect(parsed[:source]).to be_frozen
      expect(parsed[:tags]).to be_frozen
      expect(parsed[:tags].first).to be_frozen
      expect { parsed[:source][:service_type].replace("github") }.to raise_error(FrozenError)
      expect { parsed[:tags] << "eng" }.to raise_error(FrozenError)
    end

    it "refreshes the cached value when payload changes" do
      entry = described_class.new(valid_entry_attrs)
      original = entry.parsed_payload

      entry.payload = {
        contract_version: 1,
        idempotency_key: valid_entry_attrs[:idempotency_key],
        title: "Updated"
      }.to_json

      updated = entry.parsed_payload

      expect(updated).not_to equal(original)
      expect(updated).to include(title: "Updated")
      expect(original).not_to have_key(:title)
    end
  end
end
