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

    it "raises when source is missing required fields" do
      expect do
        described_class.new(**valid_attrs, source: { service_type: "asana" })
      end.to raise_error(ArgumentError, /source/)
    end

    it "raises when observed_at is not parseable as ISO 8601" do
      expect { described_class.new(**valid_attrs, observed_at: "Aug 14 2026") }
        .to raise_error(ArgumentError, /invalid ISO 8601 timestamp/)
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

    it "raises when is_deleted is not a boolean" do
      expect { described_class.new(**valid_attrs, is_deleted: "yes") }
        .to raise_error(ArgumentError, /is_deleted/)
    end

    it "accepts is_deleted false" do
      expect { described_class.new(**valid_attrs, is_deleted: false) }.not_to raise_error
    end

    it "raises when an optional timestamp is not parseable as ISO 8601" do
      expect { described_class.new(**valid_attrs, completed_at: "yesterday") }
        .to raise_error(ArgumentError, /invalid ISO 8601 timestamp/)
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
      expect(payload.keys).not_to include(:change, :provenance, :last_known)
    end

    it "includes change when provided" do
      obs = described_class.new(**valid_attrs, change: { field: "status", from: "open", to: "completed" })
      expect(obs.to_payload[:change]).to eq({ field: "status", from: "open", to: "completed" })
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
