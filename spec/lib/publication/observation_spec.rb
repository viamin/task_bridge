# frozen_string_literal: true

require "rails_helper"

RSpec.describe Publication::Observation do
  let(:valid_source) do
    { service_type: "asana", service_instance: "asana:workspace-12345:default", external_id: "1201234567890" }
  end

  let(:valid_attrs) do
    {
      idempotency_key: "tb:v1:obs:asana:workspace-12345:default:1201234567890:source_changed:2026-08-14T19:20:31.123456Z",
      event_type: "source_changed",
      observed_at: "2026-08-14T19:20:31.123456Z",
      item_key: "asana:workspace-12345:default:1201234567890",
      source: valid_source
    }
  end

  describe "required field validation" do
    it "raises when idempotency_key is blank" do
      expect { described_class.new(**valid_attrs, idempotency_key: "") }.to raise_error(ArgumentError, /idempotency_key/)
    end

    it "raises when idempotency_key is not a string" do
      expect { described_class.new(**valid_attrs, idempotency_key: 42) }
        .to raise_error(ArgumentError, /idempotency_key must be a string/)
    end

    it "raises when event_type is invalid" do
      expect { described_class.new(**valid_attrs, event_type: "bad_type") }.to raise_error(ArgumentError, /event_type/)
    end

    it "raises when observed_at is nil" do
      expect { described_class.new(**valid_attrs, observed_at: nil) }.to raise_error(ArgumentError, /observed_at/)
    end

    it "raises when observed_at is a blank string" do
      expect { described_class.new(**valid_attrs, observed_at: "") }.to raise_error(ArgumentError, /observed_at/)
    end

    it "raises when item_key is blank" do
      expect { described_class.new(**valid_attrs, item_key: "") }.to raise_error(ArgumentError, /item_key/)
    end

    it "raises when item_key is not a string" do
      expect { described_class.new(**valid_attrs, item_key: 42) }
        .to raise_error(ArgumentError, /item_key must be a string/)
    end

    it "raises when source is nil" do
      expect { described_class.new(**valid_attrs, source: nil) }.to raise_error(ArgumentError, /source is required/)
    end

    it "raises when source is missing required fields" do
      expect do
        described_class.new(**valid_attrs, source: { service_type: "asana" })
      end.to raise_error(ArgumentError, /source/)
    end

    it "raises when source is not a hash" do
      expect { described_class.new(**valid_attrs, source: "asana") }
        .to raise_error(ArgumentError, /source must be a hash/)
    end

    it "raises when a source identity field is not a string" do
      expect do
        described_class.new(**valid_attrs, source: valid_source.merge(service_type: :asana))
      end.to raise_error(ArgumentError, /source required fields must be strings: service_type/)
    end

    it "raises when source_url is not a string" do
      expect do
        described_class.new(**valid_attrs, source: valid_source.merge(source_url: 42))
      end.to raise_error(ArgumentError, /source\.source_url must be a string/)
    end

    it "raises when source_collection_keys is not an array" do
      expect do
        described_class.new(**valid_attrs, source: valid_source.merge(source_collection_keys: "project-9"))
      end.to raise_error(ArgumentError, /source\.source_collection_keys must be an array/)
    end

    it "raises when a source_collection_keys entry is not an object" do
      expect do
        described_class.new(**valid_attrs, source: valid_source.merge(source_collection_keys: ["project-9"]))
      end.to raise_error(ArgumentError, /source\.source_collection_keys must be an array of objects/)
    end

    it "raises when a source_collection_keys entry is missing kind or id" do
      expect do
        described_class.new(**valid_attrs, source: valid_source.merge(source_collection_keys: [{ id: "project-9" }]))
      end.to raise_error(ArgumentError, /source\.source_collection_keys/)
      expect do
        described_class.new(**valid_attrs, source: valid_source.merge(source_collection_keys: [{ kind: "project" }]))
      end.to raise_error(ArgumentError, /source\.source_collection_keys/)
    end

    it "raises when a source_collection_keys entry has wrong-typed or blank values" do
      [{ kind: 42, id: "project-9" }, { kind: "project", id: 42 },
       { kind: "", id: "project-9" }, { kind: "project", id: "" }].each do |entry|
        expect do
          described_class.new(**valid_attrs, source: valid_source.merge(source_collection_keys: [entry]))
        end.to raise_error(ArgumentError, /source\.source_collection_keys/)
      end
    end

    it "raises when a source_collection_keys entry carries invalid UTF-8 instead of crashing on presence" do
      expect do
        described_class.new(**valid_attrs, source: valid_source.merge(source_collection_keys: [{ kind: (+"proj\xff").force_encoding("UTF-8"), id: "project-9" }]))
      end.to raise_error(ArgumentError, /source\.source_collection_keys/)
    end

    it "raises when observed_at is not parseable as ISO 8601" do
      expect { described_class.new(**valid_attrs, observed_at: "Aug 14 2026") }
        .to raise_error(ArgumentError, /invalid ISO 8601 timestamp/)
    end

    it "raises when idempotency_key contains invalid UTF-8 byte sequences" do
      expect { described_class.new(**valid_attrs, idempotency_key: (+"tb:v1:\xff").force_encoding("UTF-8")) }
        .to raise_error(ArgumentError, /idempotency_key must be valid UTF-8/)
    end

    it "raises when item_key contains invalid UTF-8 byte sequences" do
      expect { described_class.new(**valid_attrs, item_key: (+"asana:\xff").force_encoding("UTF-8")) }
        .to raise_error(ArgumentError, /item_key must be valid UTF-8/)
    end

    it "raises when a source identity field contains invalid UTF-8 byte sequences" do
      expect do
        described_class.new(**valid_attrs, source: valid_source.merge(service_instance: (+"asana:\xff").force_encoding("UTF-8")))
      end.to raise_error(ArgumentError, /source\.service_instance must be valid UTF-8/)
    end

    it "raises when the change field name contains invalid UTF-8 byte sequences" do
      expect { described_class.new(**valid_attrs, change: { field: (+"stat\xff").force_encoding("UTF-8"), from: "open", to: "done" }) }
        .to raise_error(ArgumentError, /change\.field must be valid UTF-8/)
    end
  end

  describe "optional field validation" do
    it "raises when change is not a hash" do
      expect { described_class.new(**valid_attrs, change: "status") }
        .to raise_error(ArgumentError, /change/)
    end

    it "raises when change has no field name" do
      expect { described_class.new(**valid_attrs, change: { from: "open", to: "completed" }) }
        .to raise_error(ArgumentError, /change/)
    end

    it "raises when change has a blank field name" do
      expect { described_class.new(**valid_attrs, change: { field: "" }) }
        .to raise_error(ArgumentError, /change/)
    end

    it "raises when the change field name is not a string" do
      expect { described_class.new(**valid_attrs, change: { field: 42, from: "open", to: "completed" }) }
        .to raise_error(ArgumentError, /change/)
    end

    it "raises when change is missing the from key" do
      expect { described_class.new(**valid_attrs, change: { field: "status", to: "completed" }) }
        .to raise_error(ArgumentError, /change/)
    end

    it "raises when change is missing the to key" do
      expect { described_class.new(**valid_attrs, change: { field: "status", from: "open" }) }
        .to raise_error(ArgumentError, /change/)
    end

    it "accepts a change whose from or to value is nil" do
      obs = described_class.new(**valid_attrs, change: { field: "due_at", from: nil, to: "2026-08-15T17:00:00Z" })
      expect(obs.to_payload[:change][:from]).to be_nil
      expect(obs.to_payload[:change][:to]).to eq("2026-08-15T17:00:00Z")
    end

    it "raises when nested change text contains invalid UTF-8 byte sequences" do
      expect do
        described_class.new(
          **valid_attrs,
          change: { field: "notes_preview", from: (+"old \xff").force_encoding("UTF-8"), to: "new" }
        )
      end.to raise_error(ArgumentError, /change\.from must be valid UTF-8/)
    end

    it "raises when is_deleted is not a boolean" do
      expect { described_class.new(**valid_attrs, is_deleted: "yes") }
        .to raise_error(ArgumentError, /is_deleted/)
    end

    it "raises when last_known is not a hash" do
      expect { described_class.new(**valid_attrs, last_known: "Buy milk") }
        .to raise_error(ArgumentError, /last_known/)
    end

    it "raises when provenance is not a hash" do
      expect { described_class.new(**valid_attrs, provenance: "detected by sync_compare") }
        .to raise_error(ArgumentError, /provenance/)
    end

    it "raises when nested last_known text contains invalid UTF-8 byte sequences" do
      expect do
        described_class.new(
          **valid_attrs,
          last_known: { title: (+"Buy \xff").force_encoding("UTF-8") }
        )
      end.to raise_error(ArgumentError, /last_known\.title must be valid UTF-8/)
    end

    it "raises when nested provenance text contains invalid UTF-8 byte sequences" do
      expect do
        described_class.new(
          **valid_attrs,
          provenance: { detector: { rule: (+"sync \xff").force_encoding("UTF-8") } }
        )
      end.to raise_error(ArgumentError, /provenance\.detector\.rule must be valid UTF-8/)
    end

    it "accepts is_deleted false" do
      expect { described_class.new(**valid_attrs, is_deleted: false) }.not_to raise_error
    end

    it "raises when an optional timestamp is not parseable as ISO 8601" do
      expect { described_class.new(**valid_attrs, completed_at: "yesterday") }
        .to raise_error(ArgumentError, /invalid ISO 8601 timestamp/)
    end

    it "raises when observed_at contains invalid UTF-8 byte sequences" do
      expect { described_class.new(**valid_attrs, observed_at: (+"2026-08-14T19:20:31Z\xff").force_encoding("UTF-8")) }
        .to raise_error(ArgumentError, /observed_at must be valid UTF-8/)
    end

    it "raises when an optional timestamp contains invalid UTF-8 byte sequences" do
      expect { described_class.new(**valid_attrs, published_at: (+"2026-08-14T19:20:33Z\xff").force_encoding("UTF-8")) }
        .to raise_error(ArgumentError, /published_at must be valid UTF-8/)
    end
  end

  describe "#to_payload" do
    subject(:payload) { described_class.new(**valid_attrs).to_payload }

    it "includes contract_version 1" do
      expect(payload[:contract_version]).to eq(1)
    end

    it "includes event_type and item_key" do
      expect(payload[:event_type]).to eq("source_changed")
      expect(payload[:item_key]).to eq("asana:workspace-12345:default:1201234567890")
    end

    it "omits nil optional fields" do
      expect(payload.keys).not_to include(:change, :provenance, :last_known, :is_deleted, :published_at)
    end

    it "includes change when provided" do
      obs = described_class.new(**valid_attrs, change: { field: "status", from: "open", to: "completed" })
      expect(obs.to_payload[:change]).to eq({ field: "status", from: "open", to: "completed" })
    end

    it "includes published_at in canonical form when provided" do
      obs = described_class.new(**valid_attrs, published_at: "2026-08-14T19:20:33Z")
      expect(obs.to_payload[:published_at]).to eq("2026-08-14T19:20:33.000000Z")
    end

    it "includes is_deleted on tombstone observations" do
      obs = described_class.new(**valid_attrs, event_type: "deleted", is_deleted: true, last_known: { title: "Buy milk" })
      payload = obs.to_payload
      expect(payload[:is_deleted]).to be true
      expect(payload[:last_known]).to eq({ title: "Buy milk" })
    end

    it "accepts all valid event_types" do
      %w[snapshot_seen source_changed deleted].each do |et|
        expect { described_class.new(**valid_attrs, event_type: et) }.not_to raise_error
      end
    end
  end

  describe "RECORD_KIND" do
    it "is 'observation'" do
      expect(described_class::RECORD_KIND).to eq("observation")
    end
  end
end
