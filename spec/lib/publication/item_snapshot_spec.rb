# frozen_string_literal: true

require "rails_helper"

RSpec.describe Publication::ItemSnapshot do
  let(:valid_source) do
    { service_type: "asana", service_instance: "asana:workspace-12345:default", external_id: "1201234567890" }
  end

  let(:valid_attrs) do
    {
      idempotency_key: "tb:v1:item:asana:workspace-12345:default:1201234567890:snapshot:2026-08-14T19:20:31.123456Z",
      item_key: "asana:workspace-12345:default:1201234567890",
      observed_at: "2026-08-14T19:20:31.123456Z",
      title: "Buy milk",
      status: "open",
      is_deleted: false,
      source: valid_source
    }
  end

  describe "required field validation" do
    it "raises when idempotency_key is blank" do
      expect { described_class.new(**valid_attrs, idempotency_key: "") }.to raise_error(ArgumentError, /idempotency_key/)
    end

    it "raises when item_key is blank" do
      expect { described_class.new(**valid_attrs, item_key: nil) }.to raise_error(ArgumentError, /item_key/)
    end

    it "raises when observed_at is nil" do
      expect { described_class.new(**valid_attrs, observed_at: nil) }.to raise_error(ArgumentError, /observed_at/)
    end

    it "raises when observed_at is a blank string" do
      expect { described_class.new(**valid_attrs, observed_at: "") }.to raise_error(ArgumentError, /observed_at/)
    end

    it "raises when title is blank" do
      expect { described_class.new(**valid_attrs, title: "") }.to raise_error(ArgumentError, /title/)
    end

    it "raises when status is invalid" do
      expect { described_class.new(**valid_attrs, status: "unknown") }.to raise_error(ArgumentError, /status/)
    end

    it "raises when is_deleted is nil" do
      expect { described_class.new(**valid_attrs, is_deleted: nil) }.to raise_error(ArgumentError, /is_deleted/)
    end

    it "raises when is_deleted is not a boolean" do
      expect { described_class.new(**valid_attrs, is_deleted: "false") }.to raise_error(ArgumentError, /is_deleted/)
    end

    it "raises when source is nil" do
      expect { described_class.new(**valid_attrs, source: nil) }.to raise_error(ArgumentError, /source/)
    end

    it "raises when source is missing service_instance" do
      expect do
        described_class.new(**valid_attrs, source: { service_type: "asana", external_id: "1" })
      end.to raise_error(ArgumentError, /service_instance/)
    end

    it "raises when observed_at is not parseable as ISO 8601" do
      expect { described_class.new(**valid_attrs, observed_at: "14/08/2026") }
        .to raise_error(ArgumentError, /invalid ISO 8601 timestamp/)
    end

    it "raises when an optional timestamp is not parseable as ISO 8601" do
      expect { described_class.new(**valid_attrs, due_at: "tomorrow") }
        .to raise_error(ArgumentError, /invalid ISO 8601 timestamp/)
    end
  end

  describe "#to_payload" do
    subject(:payload) { described_class.new(**valid_attrs).to_payload }

    it "includes contract_version 1" do
      expect(payload[:contract_version]).to eq(1)
    end

    it "includes entity_type 'task'" do
      expect(payload[:entity_type]).to eq("task")
    end

    it "includes all required fields" do
      expect(payload).to include(:idempotency_key, :item_key, :observed_at, :title, :status, :is_deleted, :source)
    end

    it "omits nil optional fields" do
      expect(payload.keys).not_to include(:completed_at, :due_at, :started_at, :notes_preview)
    end

    it "includes notes_preview when provided" do
      snapshot = described_class.new(**valid_attrs, notes_preview: "2% and eggs")
      expect(snapshot.to_payload[:notes_preview]).to eq("2% and eggs")
    end

    it "formats a Time observed_at as ISO 8601 UTC with microseconds" do
      time = Time.utc(2026, 8, 14, 19, 20, 31, 123_456)
      snapshot = described_class.new(**valid_attrs, observed_at: time)
      expect(snapshot.to_payload[:observed_at]).to eq("2026-08-14T19:20:31.123456Z")
    end

    it "normalizes a UTC-offset observed_at string to canonical UTC" do
      snapshot = described_class.new(**valid_attrs, observed_at: "2026-08-14T21:20:31+02:00")
      expect(snapshot.to_payload[:observed_at]).to eq("2026-08-14T19:20:31.000000Z")
    end

    it "accepts all valid statuses" do
      %w[open completed dropped].each do |s|
        expect { described_class.new(**valid_attrs, status: s) }.not_to raise_error
      end
    end
  end

  describe "RECORD_KIND" do
    it "is 'item'" do
      expect(described_class::RECORD_KIND).to eq("item")
    end
  end
end
