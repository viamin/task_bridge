# frozen_string_literal: true

require "rails_helper"

RSpec.describe Publication::IdempotencyKey do
  let(:service_instance) { "asana:workspace-12345:default" }
  let(:external_id) { "1201234567890" }
  let(:observed_at_str) { "2026-08-14T19:20:31.123456Z" }
  let(:observed_at_time) { Time.utc(2026, 8, 14, 19, 20, 31, 123_456) }

  describe ".for_item" do
    it "builds a deterministic item snapshot key from a string timestamp" do
      key = described_class.for_item(
        service_instance:, external_id:, observed_at: observed_at_str
      )
      expect(key).to eq("tb:v1:item:asana:workspace-12345:default:1201234567890:snapshot:2026-08-14T19:20:31.123456Z")
    end

    it "formats a Time value to ISO 8601 UTC with microseconds" do
      key = described_class.for_item(
        service_instance:, external_id:, observed_at: observed_at_time
      )
      expect(key).to eq("tb:v1:item:asana:workspace-12345:default:1201234567890:snapshot:2026-08-14T19:20:31.123456Z")
    end

    it "produces the same key when called twice with the same arguments" do
      args = { service_instance:, external_id:, observed_at: observed_at_str }
      expect(described_class.for_item(**args)).to eq(described_class.for_item(**args))
    end

    it "raises when a key segment is blank" do
      expect do
        described_class.for_item(service_instance: "", external_id:, observed_at: observed_at_str)
      end.to raise_error(ArgumentError, /blank key segment/)
    end

    it "raises when observed_at is nil" do
      expect do
        described_class.for_item(service_instance:, external_id:, observed_at: nil)
      end.to raise_error(ArgumentError, /observed_at/)
    end

    it "raises when observed_at is not parseable as ISO 8601" do
      expect do
        described_class.for_item(service_instance:, external_id:, observed_at: "whenever")
      end.to raise_error(ArgumentError, /invalid ISO 8601 timestamp/)
    end

    it "normalizes a UTC-offset timestamp so equivalent instants share a key" do
      utc = described_class.for_item(service_instance:, external_id:, observed_at: "2026-08-14T19:20:31Z")
      offset = described_class.for_item(service_instance:, external_id:, observed_at: "2026-08-14T21:20:31+02:00")
      expect(offset).to eq(utc)
    end
  end

  describe ".for_observation" do
    it "builds an observation key with the event_type segment" do
      key = described_class.for_observation(
        service_instance:, external_id:, event_type: "source_changed", observed_at: observed_at_str
      )
      expect(key).to eq("tb:v1:obs:asana:workspace-12345:default:1201234567890:source_changed:2026-08-14T19:20:31.123456Z")
    end

    it "uses a different prefix than item keys for the same fact" do
      item_key = described_class.for_item(service_instance:, external_id:, observed_at: observed_at_str)
      obs_key  = described_class.for_observation(service_instance:, external_id:, event_type: "snapshot_seen", observed_at: observed_at_str)
      expect(item_key).not_to eq(obs_key)
    end
  end

  describe ".for_mapping" do
    it "builds a mapping key with sync_collection_id and member identity" do
      key = described_class.for_mapping(
        sync_collection_id: 84,
        service_instance:,
        external_id:,
        observed_at: observed_at_str
      )
      expect(key).to eq(
        "tb:v1:map:sync_collection:84:membership:asana:workspace-12345:default:1201234567890:2026-08-14T19:20:31.123456Z"
      )
    end

    it "produces distinct keys for different observed_at values on the same membership" do
      base_args = { sync_collection_id: 84, service_instance:, external_id: }
      key1 = described_class.for_mapping(**base_args, observed_at: "2026-08-14T19:21:00.000000Z")
      key2 = described_class.for_mapping(**base_args, observed_at: "2026-08-14T20:00:00.000000Z")
      expect(key1).not_to eq(key2)
    end
  end

  describe ".for_sync_run" do
    it "builds a sync-run key using service_instance and sync_run_id" do
      key = described_class.for_sync_run(
        service_instance:,
        sync_run_id: "sync-run-20260814T192000Z-asana"
      )
      expect(key).to eq("tb:v1:sync_run:asana:workspace-12345:default:sync-run-20260814T192000Z-asana")
    end

    it "does not include a timestamp segment" do
      key = described_class.for_sync_run(service_instance:, sync_run_id: "run-1")
      expect(key).not_to include("T")
    end
  end
end
