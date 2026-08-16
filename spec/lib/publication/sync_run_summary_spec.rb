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
      last_successful_at: "2026-08-14T19:21:05.000000Z",
      status: "success",
      items_synced: 12
    }
  end

  describe "required field validation" do
    %i[idempotency_key sync_run_id service_type service_instance].each do |field|
      it "raises when #{field} is blank" do
        expect { described_class.new(**valid_attrs, field => "") }.to raise_error(ArgumentError, /#{field}/)
      end

      it "raises when #{field} is not a string" do
        expect { described_class.new(**valid_attrs, field => 42) }
          .to raise_error(ArgumentError, /#{field} must be a string/)
      end
    end

    %i[started_at finished_at last_attempted_at last_successful_at].each do |field|
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

    it "raises when items_synced is negative" do
      expect { described_class.new(**valid_attrs, items_synced: -1) }.to raise_error(ArgumentError, /items_synced/)
    end

    it "raises when items_synced is not an integer" do
      expect { described_class.new(**valid_attrs, items_synced: "12") }.to raise_error(ArgumentError, /items_synced/)
    end

    it "raises when touched_collection_ids is not an array" do
      expect { described_class.new(**valid_attrs, touched_collection_ids: 84) }
        .to raise_error(ArgumentError, /touched_collection_ids/)
    end

    it "raises when a touched_collection_ids entry is not an integer" do
      expect { described_class.new(**valid_attrs, touched_collection_ids: [84, "91"]) }
        .to raise_error(ArgumentError, /touched_collection_ids must be an array of unique non-negative integers/)
    end

    it "raises when a touched_collection_ids entry is negative" do
      expect { described_class.new(**valid_attrs, touched_collection_ids: [84, -1]) }
        .to raise_error(ArgumentError, /touched_collection_ids must be an array of unique non-negative integers/)
    end

    it "raises when touched_collection_ids contains duplicates" do
      expect { described_class.new(**valid_attrs, touched_collection_ids: [84, 84]) }
        .to raise_error(ArgumentError, /touched_collection_ids must be an array of unique non-negative integers/)
    end

    it "raises when detail is not a string" do
      expect { described_class.new(**valid_attrs, detail: 12) }
        .to raise_error(ArgumentError, /detail/)
    end

    it "raises when a required timestamp is not parseable as ISO 8601" do
      expect { described_class.new(**valid_attrs, finished_at: "never") }
        .to raise_error(ArgumentError, /invalid ISO 8601 timestamp/)
    end

    it "raises when a required timestamp contains invalid UTF-8 byte sequences" do
      expect { described_class.new(**valid_attrs, started_at: (+"2026-08-14T19:20:00Z\xff").force_encoding("UTF-8")) }
        .to raise_error(ArgumentError, /started_at must be valid UTF-8/)
    end

    it "raises when an optional completion timestamp contains invalid UTF-8 byte sequences" do
      expect { described_class.new(**valid_attrs, last_failed_at: (+"2026-08-14T19:21:05Z\xff").force_encoding("UTF-8")) }
        .to raise_error(ArgumentError, /last_failed_at must be valid UTF-8/)
    end

    %i[idempotency_key sync_run_id service_type service_instance].each do |field|
      it "raises when #{field} contains invalid UTF-8 byte sequences" do
        expect { described_class.new(**valid_attrs, field => (+"bad \xff").force_encoding("UTF-8")) }
          .to raise_error(ArgumentError, /#{field} must be valid UTF-8/)
      end
    end
  end

  describe "completion timestamp rules" do
    it "raises when a success run omits last_successful_at" do
      expect { described_class.new(**valid_attrs, last_successful_at: nil) }
        .to raise_error(ArgumentError, /last_successful_at is required/)
    end

    it "raises when a failed run omits last_failed_at" do
      expect { described_class.new(**valid_attrs, status: "failed", last_successful_at: nil) }
        .to raise_error(ArgumentError, /last_failed_at is required/)
    end

    it "raises when a partial run omits both completion timestamps" do
      expect { described_class.new(**valid_attrs, status: "partial", last_successful_at: nil) }
        .to raise_error(ArgumentError, /last_successful_at or last_failed_at is required/)
    end

    it "accepts a failed run that carries last_failed_at" do
      summary = described_class.new(
        **valid_attrs, status: "failed", last_successful_at: nil,
                       last_failed_at: "2026-08-14T19:30:02.000000Z"
      )
      expect(summary.to_payload[:last_failed_at]).to eq("2026-08-14T19:30:02.000000Z")
    end

    it "accepts a partial run that carries at least one completion timestamp" do
      expect { described_class.new(**valid_attrs, status: "partial") }.not_to raise_error
    end
  end

  describe "optional error validation" do
    it "raises when error is not a hash" do
      expect { described_class.new(**valid_attrs, error: "ProviderError") }
        .to raise_error(ArgumentError, /error/)
    end

    it "raises when error is missing required keys" do
      expect { described_class.new(**valid_attrs, error: { class: "ProviderError", message: "401" }) }
        .to raise_error(ArgumentError, /error/)
    end

    it "accepts an error with class, message, and retryable" do
      expect do
        described_class.new(**valid_attrs, error: { class: "ProviderError", message: "401", retryable: false })
      end.not_to raise_error
    end

    it "accepts an error hash with string keys" do
      expect do
        described_class.new(
          **valid_attrs,
          error: { "class" => "ProviderError", "message" => "401", "retryable" => false }
        )
      end.not_to raise_error
    end

    it "raises when error.retryable is not a boolean" do
      expect do
        described_class.new(**valid_attrs, error: { class: "ProviderError", message: "401", retryable: "yes" })
      end.to raise_error(ArgumentError, /retryable boolean/)
    end

    it "raises when error.class is blank" do
      expect do
        described_class.new(**valid_attrs, error: { class: "", message: "401", retryable: false })
      end.to raise_error(ArgumentError, /error/)
    end

    it "raises when error.message is not a string" do
      expect do
        described_class.new(**valid_attrs, error: { class: "ProviderError", message: 401, retryable: false })
      end.to raise_error(ArgumentError, /error/)
    end

    it "raises when detail contains invalid UTF-8 byte sequences" do
      expect { described_class.new(**valid_attrs, detail: (+"12 items \xff").force_encoding("UTF-8")) }
        .to raise_error(ArgumentError, /detail must be valid UTF-8/)
    end

    it "raises when error.message contains invalid UTF-8 byte sequences" do
      expect do
        described_class.new(**valid_attrs, error: { class: "ProviderError", message: (+"401 \xff").force_encoding("UTF-8"), retryable: false })
      end.to raise_error(ArgumentError, /error\.message must be valid UTF-8/)
    end

    it "raises when nested error context contains invalid UTF-8 byte sequences" do
      expect do
        described_class.new(
          **valid_attrs,
          error: {
            class: "ProviderError",
            message: "401",
            retryable: false,
            context: { response_excerpt: (+"body \xff").force_encoding("UTF-8") }
          }
        )
      end.to raise_error(ArgumentError, /error\.context\.response_excerpt must be valid UTF-8/)
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

    it "omits optional free-text fields when not provided" do
      expect(payload.keys).not_to include(:detail, :error)
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

    it "accepts all valid statuses when the applicable completion timestamp is present" do
      expect { described_class.new(**valid_attrs, status: "success") }.not_to raise_error
      expect do
        described_class.new(**valid_attrs, status: "failed", last_successful_at: nil,
                                           last_failed_at: "2026-08-14T19:30:02.000000Z")
      end.not_to raise_error
      expect { described_class.new(**valid_attrs, status: "partial") }.not_to raise_error
    end
  end

  describe "RECORD_KIND" do
    it "is 'sync_run'" do
      expect(described_class::RECORD_KIND).to eq("sync_run")
    end
  end
end
