# frozen_string_literal: true

require "rails_helper"

RSpec.describe Publication::SyncRunSummary do
  let(:valid_attrs) do
    {
      idempotency_key: "tb:v1:sync_run:asana:workspace-12345:default:sync-run-20260814T192000Z-asana",
      sync_run_id: "sync-run-20260814T192000Z-asana",
      service_type: "asana",
      service_instance: "asana:workspace-12345:default",
      started_at: "2026-08-14T19:20:00.000000Z",
      finished_at: "2026-08-14T19:21:05.000000Z",
      last_attempted_at: "2026-08-14T19:20:00.000000Z",
      status: "success",
      items_synced: 12
    }
  end

  describe "required field validation" do
    %i[idempotency_key sync_run_id service_type service_instance].each do |field|
      it "raises when #{field} is blank" do
        expect { described_class.new(**valid_attrs, field => "") }.to raise_error(ArgumentError, /#{field}/)
      end
    end

    %i[started_at finished_at last_attempted_at].each do |field|
      it "raises when #{field} is nil" do
        expect { described_class.new(**valid_attrs, field => nil) }.to raise_error(ArgumentError, /#{field}/)
      end

      it "raises when #{field} is a blank string" do
        expect { described_class.new(**valid_attrs, field => "") }.to raise_error(ArgumentError, /#{field}/)
      end
    end

    it "raises when status is invalid" do
      expect { described_class.new(**valid_attrs, status: "running") }.to raise_error(ArgumentError, /status/)
    end

    it "raises when items_synced is nil" do
      expect { described_class.new(**valid_attrs, items_synced: nil) }.to raise_error(ArgumentError, /items_synced/)
    end
  end

  describe "#to_payload" do
    subject(:payload) { described_class.new(**valid_attrs).to_payload }

    it "includes contract_version 1" do
      expect(payload[:contract_version]).to eq(1)
    end

    it "includes all required fields" do
      expect(payload).to include(
        :sync_run_id, :service_type, :service_instance,
        :started_at, :finished_at, :last_attempted_at,
        :status, :items_synced
      )
    end

    it "defaults touched_collection_ids to an empty array" do
      expect(payload[:touched_collection_ids]).to eq([])
    end

    it "includes touched_collection_ids when provided" do
      summary = described_class.new(**valid_attrs, touched_collection_ids: [84, 91])
      expect(summary.to_payload[:touched_collection_ids]).to eq([84, 91])
    end

    it "includes last_successful_at and last_failed_at for a success run" do
      summary = described_class.new(
        **valid_attrs,
        last_successful_at: "2026-08-14T19:21:05.000000Z",
        last_failed_at: nil
      )
      p = summary.to_payload
      expect(p[:last_successful_at]).to eq("2026-08-14T19:21:05.000000Z")
      expect(p.key?(:last_failed_at)).to be false
    end

    it "includes error details for a failed run" do
      summary = described_class.new(
        **valid_attrs, status: "failed", items_synced: 0,
                       last_failed_at: "2026-08-14T19:30:02.000000Z",
                       error: { class: "ProviderError", message: "401 unauthorized", retryable: false }
      )
      p = summary.to_payload
      expect(p[:status]).to eq("failed")
      expect(p[:error][:message]).to eq("401 unauthorized")
    end

    it "accepts all valid statuses" do
      %w[success failed partial].each do |s|
        expect { described_class.new(**valid_attrs, status: s) }.not_to raise_error
      end
    end
  end

  describe "RECORD_KIND" do
    it "is 'sync_run'" do
      expect(described_class::RECORD_KIND).to eq("sync_run")
    end
  end
end
