# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::IdempotencyKey do
  let(:observed_at) { Time.zone.parse("2026-08-14T19:20:31.123456Z") }

  describe ".for" do
    it "builds item snapshot keys ending in the observed timestamp" do
      key = described_class.for(
        record_kind: :item,
        observed_at:,
        service_instance: "asana:workspace-12345:default",
        external_id: "1201234567890"
      )

      expect(key).to eq("tb:v1:item:asana:workspace-12345:default:1201234567890:snapshot:2026-08-14T19:20:31.123456Z")
    end

    it "builds observation keys carrying the event type" do
      key = described_class.for(
        record_kind: :observation,
        observed_at:,
        service_instance: "asana:workspace-12345:default",
        external_id: "1201234567890",
        event_type: "source_changed"
      )

      expect(key).to eq("tb:v1:obs:asana:workspace-12345:default:1201234567890:source_changed:2026-08-14T19:20:31.123456Z")
    end

    it "builds mapping keys carrying the collection scope and member identity" do
      key = described_class.for(
        record_kind: :mapping,
        observed_at:,
        sync_collection_id: 84,
        service_instance: "github:repo-1",
        external_id: "issue-42"
      )

      expect(key).to eq("tb:v1:map:sync_collection:84:membership:github:repo-1:issue-42:2026-08-14T19:20:31.123456Z")
    end

    it "builds sync-run keys scoped by the run instead of item identity" do
      key = described_class.for(
        record_kind: :sync_run,
        observed_at:,
        service_instance: "asana:workspace-12345:default",
        sync_run_id: "sync-run-20260814T192000Z-asana"
      )

      expect(key).to eq("tb:v1:sync_run:asana:workspace-12345:default:sync-run-20260814T192000Z-asana")
    end

    it "normalizes observed_at to UTC with microseconds" do
      zoned = Time.zone.parse("2026-08-14T21:20:31.123456+02:00")

      key = described_class.for(
        record_kind: :item,
        observed_at: zoned,
        service_instance: "asana:default",
        external_id: "1201"
      )

      expect(key).to end_with(":snapshot:2026-08-14T19:20:31.123456Z")
    end

    it "raises for unknown record kinds" do
      expect { described_class.for(record_kind: :bogus, observed_at:) }
        .to raise_error(ArgumentError, /unknown record_kind/)
    end

    it "raises KeyError when an identity segment is missing" do
      expect do
        described_class.for(record_kind: :observation, observed_at:, service_instance: "asana:default")
      end.to raise_error(KeyError)
    end
  end
end
