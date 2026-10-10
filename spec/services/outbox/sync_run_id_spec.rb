# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunId do
  let(:run_started_at) { Time.zone.parse("2026-08-14T19:20:00Z") }

  describe ".for" do
    it "builds the RDR #215 run scope from a time" do
      expect(described_class.for("Asana", at: run_started_at)).to eq("sync-run-20260814T192000Z-asana")
    end

    it "accepts the iso8601 string the sync task stamps as sync_started_at" do
      expect(described_class.for("Asana", at: "2026-08-14T19:20:00.000000Z")).to eq("sync-run-20260814T192000Z-asana")
    end

    it "qualifies the service identifier with the configured instance name" do
      expect(described_class.for("Asana:work", at: run_started_at)).to eq("sync-run-20260814T192000Z-asana_work")
    end

    it "normalizes zoned times to UTC" do
      zoned = Time.zone.parse("2026-08-14T21:20:00.000000+02:00")

      expect(described_class.for("Github", at: zoned)).to eq("sync-run-20260814T192000Z-github")
    end

    it "returns nil for blank input so callers can omit the fact" do
      expect(described_class.for("Asana", at: nil)).to be_nil
      expect(described_class.for("Asana", at: "")).to be_nil
    end
  end

  describe ".parse" do
    it "passes through time-like values" do
      expect(described_class.parse(run_started_at)).to eq(run_started_at)
    end

    it "parses timestamp strings" do
      expect(described_class.parse("2026-08-14T19:20:00.000000Z")).to eq(run_started_at)
    end

    it "yields nil for blank or unparseable input" do
      expect(described_class.parse(nil)).to be_nil
      expect(described_class.parse("")).to be_nil
    end
  end
end
