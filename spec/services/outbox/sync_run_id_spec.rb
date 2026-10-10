# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::SyncRunId do
  describe ".for" do
    it "builds the RDR #215 sync-run scope from a Time object" do
      at = Time.zone.parse("2026-08-14T19:20:00Z")

      expect(described_class.for("Asana", at:)).to eq("sync-run-20260814T192000Z-asana")
    end

    it "parses the run-scope ISO 8601 string the rake task stores in options" do
      started_at = "2026-10-05T10:00:00.000000Z"

      expect(described_class.for("TestService", at: started_at)).to eq("sync-run-20261005T100000Z-test_service")
    end

    it "includes the instance qualifier for instance-scoped services" do
      at = Time.zone.parse("2026-08-14T19:20:00Z")

      expect(described_class.for("Asana:work", at:)).to eq("sync-run-20260814T192000Z-asana_work")
    end
  end
end
