# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncServiceState do
  describe ".record_summary!" do
    it "persists the provided summary fields" do
      state = described_class.record_summary!(
        "service" => "Github",
        "status" => "success",
        "items_synced" => 5,
        "last_attempted" => "2024-04-01T12:00:00.000000Z",
        "last_successful" => "2024-04-01T12:00:00.000000Z"
      )

      expect(state).to be_persisted
      expect(state.status).to eq("success")
      expect(state.items_synced).to eq(5)
      expect(state.last_attempted_at).to be_present
      expect(state.last_successful_at).to be_present
    end
  end

  describe ".record_activity_sync!" do
    it "advances the activity-sync cursor for a service" do
      described_class.record_summary!(
        "service" => "Github",
        "status" => "success",
        "items_synced" => 0,
        "last_attempted" => "2024-04-01T12:00:00.000000Z"
      )

      state = described_class.record_activity_sync!(
        service_name: "Github",
        at: Time.zone.parse("2024-04-01T12:00:00Z")
      )

      expect(state.last_successful_activity_sync_at).to eq(Time.zone.parse("2024-04-01T12:00:00Z"))
    end

    it "no-ops when the service name is blank" do
      expect do
        described_class.record_activity_sync!(service_name: "", at: Time.current)
      end.not_to change(described_class, :count)
    end

    it "no-ops when the timestamp is blank" do
      expect do
        described_class.record_activity_sync!(service_name: "Github", at: nil)
      end.not_to change(described_class, :count)
    end
  end

  describe "#to_log_hash" do
    it "formats every recorded timestamp as an ISO 8601 UTC string" do
      state = described_class.create!(
        service_name: "Github",
        status: "success",
        items_synced: 1,
        last_attempted_at: Time.zone.parse("2024-04-01T12:00:00Z"),
        last_successful_at: Time.zone.parse("2024-04-01T12:00:01Z"),
        last_successful_activity_sync_at: Time.zone.parse("2024-04-01T12:00:02Z"),
        last_failed_at: Time.zone.parse("2024-04-01T12:00:03Z"),
        detail: "Pruned completed items"
      )

      expect(state.to_log_hash).to include(
        "service" => "Github",
        "status" => "success",
        "items_synced" => 1,
        "last_successful_activity_sync" => "2024-04-01T12:00:02.000000+00:00",
        "detail" => "Pruned completed items"
      )
    end
  end
end
