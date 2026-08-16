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

    it "accepts a numeric external_id segment" do
      key = described_class.for_item(service_instance:, external_id: 42, observed_at: observed_at_str)
      expect(key).to end_with(":42:snapshot:2026-08-14T19:20:31.123456Z")
    end

    it "raises when service_instance is an integer instead of a string" do
      expect do
        described_class.for_item(service_instance: 42, external_id:, observed_at: observed_at_str)
      end.to raise_error(ArgumentError, /key segment\(s\) must be a string: service_instance/)
    end

    it "raises when a key segment is neither a string nor integer" do
      expect do
        described_class.for_item(service_instance: { workspace: 1 }, external_id:, observed_at: observed_at_str)
      end.to raise_error(ArgumentError, /key segment\(s\) must be a string: service_instance/)
    end

    it "raises when a key segment is an array" do
      expect do
        described_class.for_observation(service_instance:, external_id: ["1"], event_type: "source_changed",
                                        observed_at: observed_at_str)
      end.to raise_error(ArgumentError, /key segment\(s\) must be a string or integer: external_id/)
    end

    it "raises when a key segment is a boolean" do
      expect do
        described_class.for_sync_run(service_instance:, sync_run_id: true)
      end.to raise_error(ArgumentError, /key segment\(s\) must be a string: sync_run_id/)
    end

    it "raises when a key segment is a float" do
      expect do
        described_class.for_item(service_instance:, external_id: 42.5, observed_at: observed_at_str)
      end.to raise_error(ArgumentError, /key segment\(s\) must be a string or integer: external_id/)
    end

    it "raises when a key segment contains invalid UTF-8 byte sequences" do
      expect do
        described_class.for_item(service_instance: (+"asana:\xff").force_encoding("UTF-8"), external_id:, observed_at: observed_at_str)
      end.to raise_error(ArgumentError, /service_instance must be valid UTF-8/)
    end

    it "raises when observed_at contains invalid UTF-8 byte sequences" do
      expect do
        described_class.for_item(service_instance:, external_id:, observed_at: (+"2026-08-14T19:20:31Z\xff").force_encoding("UTF-8"))
      end.to raise_error(ArgumentError, /observed_at must be valid UTF-8/)
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

    it "ends the key with the sequence segment when timestamps collide" do
      key = described_class.for_observation(
        service_instance:, external_id:, event_type: "source_changed", sequence: 2
      )
      expect(key).to eq("tb:v1:obs:asana:workspace-12345:default:1201234567890:source_changed:2")
    end

    it "builds distinct sequence keys for transitions sharing an observed_at" do
      args = { service_instance:, external_id:, event_type: "source_changed" }
      expect(described_class.for_observation(**args, sequence: 1))
        .not_to eq(described_class.for_observation(**args, sequence: 2))
    end

    it "accepts a zero sequence so 0-based caller indices are not rejected" do
      key = described_class.for_observation(
        service_instance:, external_id:, event_type: "source_changed", sequence: 0
      )
      expect(key).to end_with(":source_changed:0")
    end

    it "raises when both observed_at and sequence are provided" do
      expect do
        described_class.for_observation(service_instance:, external_id:, event_type: "source_changed",
                                        observed_at: observed_at_str, sequence: 1)
      end.to raise_error(ArgumentError, /not both/)
    end

    it "raises when neither observed_at nor sequence is provided" do
      expect do
        described_class.for_observation(service_instance:, external_id:, event_type: "source_changed")
      end.to raise_error(ArgumentError, /observed_at or sequence is required/)
    end

    it "raises when event_type is an integer instead of a string" do
      expect do
        described_class.for_observation(service_instance:, external_id:, event_type: 7, observed_at: observed_at_str)
      end.to raise_error(ArgumentError, /key segment\(s\) must be a string: event_type/)
    end

    it "raises when sequence is a blank string" do
      expect do
        described_class.for_observation(service_instance:, external_id:, event_type: "source_changed", sequence: "")
      end.to raise_error(ArgumentError, /sequence must not be blank/)
    end

    it "raises when sequence is a whitespace-only string" do
      expect do
        described_class.for_observation(service_instance:, external_id:, event_type: "source_changed", sequence: "   ")
      end.to raise_error(ArgumentError, /sequence must not be blank/)
    end

    it "raises when sequence is neither a string nor integer" do
      expect do
        described_class.for_observation(service_instance:, external_id:, event_type: "source_changed", sequence: [])
      end.to raise_error(ArgumentError, /sequence must be a string or integer/)
    end

    it "raises when a boolean sequence is passed instead of an integer" do
      expect do
        described_class.for_observation(service_instance:, external_id:, event_type: "source_changed", sequence: true)
      end.to raise_error(ArgumentError, /sequence must be a string or integer/)
    end

    it "raises when a float sequence is passed" do
      expect do
        described_class.for_observation(service_instance:, external_id:, event_type: "source_changed", sequence: 1.5)
      end.to raise_error(ArgumentError, /sequence must be a string or integer/)
    end

    it "raises when sequence contains invalid UTF-8 byte sequences" do
      expect do
        described_class.for_observation(
          service_instance:, external_id:, event_type: "source_changed", sequence: (+"seq\xff").force_encoding("UTF-8")
        )
      end.to raise_error(ArgumentError, /sequence must be valid UTF-8/)
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

    it "ends the key with the sequence segment when timestamps collide" do
      key = described_class.for_mapping(sync_collection_id: 84, service_instance:, external_id:, sequence: 3)
      expect(key).to eq("tb:v1:map:sync_collection:84:membership:asana:workspace-12345:default:1201234567890:3")
    end

    it "accepts a zero sequence so 0-based caller indices are not rejected" do
      key = described_class.for_mapping(sync_collection_id: 84, service_instance:, external_id:, sequence: 0)
      expect(key).to end_with(":0")
    end

    it "raises when both observed_at and sequence are provided" do
      expect do
        described_class.for_mapping(sync_collection_id: 84, service_instance:, external_id:,
                                    observed_at: observed_at_str, sequence: 1)
      end.to raise_error(ArgumentError, /not both/)
    end

    it "raises when neither observed_at nor sequence is provided" do
      expect do
        described_class.for_mapping(sync_collection_id: 84, service_instance:, external_id:)
      end.to raise_error(ArgumentError, /observed_at or sequence is required/)
    end

    it "raises when sequence is a whitespace-only string" do
      expect do
        described_class.for_mapping(sync_collection_id: 84, service_instance:, external_id:, sequence: "  ")
      end.to raise_error(ArgumentError, /sequence must not be blank/)
    end

    it "raises when sequence is neither a string nor integer" do
      expect do
        described_class.for_mapping(sync_collection_id: 84, service_instance:, external_id:, sequence: { index: 1 })
      end.to raise_error(ArgumentError, /sequence must be a string or integer/)
    end

    it "raises when sync_collection_id is a float" do
      expect do
        described_class.for_mapping(sync_collection_id: 84.5, service_instance:, external_id:, observed_at: observed_at_str)
      end.to raise_error(ArgumentError, /key segment\(s\) must be a string or integer: sync_collection_id/)
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

    it "raises when a key segment is blank" do
      expect do
        described_class.for_sync_run(service_instance:, sync_run_id: "")
      end.to raise_error(ArgumentError, /blank key segment/)
    end

    it "raises when sync_run_id is an integer instead of a string" do
      expect do
        described_class.for_sync_run(service_instance:, sync_run_id: 42)
      end.to raise_error(ArgumentError, /key segment\(s\) must be a string: sync_run_id/)
    end

    it "does not include a timestamp segment" do
      key = described_class.for_sync_run(service_instance:, sync_run_id: "run-1")
      expect(key).not_to include("T")
    end
  end
end
