# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunId do
  it "builds the RDR-format id from a service name and Time" do
    at = Time.zone.parse("2026-08-14T19:20:00Z")

    expect(described_class.for("Asana:work", at:)).to eq("sync-run-20260814T192000Z-asana_work")
  end

  it "accepts the ISO string the sync task stores in options[:sync_started_at]" do
    expect(described_class.for("Asana", at: "2026-08-14T19:20:00.123456Z")).to eq("sync-run-20260814T192000Z-asana")
  end

  it "normalizes to UTC before compacting" do
    at = Time.zone.parse("2026-08-14T21:20:00+02:00")

    expect(described_class.for("Github", at:)).to eq("sync-run-20260814T192000Z-github")
  end
end
