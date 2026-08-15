# frozen_string_literal: true

require "rails_helper"

RSpec.describe Publication::Utf8 do
  describe ".validate_fields!" do
    it "raises ArgumentError naming every string field with an invalid encoding" do
      invalid = (+"asana:\xff").force_encoding("UTF-8")
      expect do
        described_class.validate_fields!({ service_instance: invalid, external_id: (+"1\xff").force_encoding("UTF-8") })
      end.to raise_error(ArgumentError, /service_instance, external_id must be valid UTF-8/)
    end

    it "accepts valid UTF-8 strings" do
      expect { described_class.validate_fields!({ service_instance: "asana:default", title: "Buy milk — ünïcode" }) }
        .not_to raise_error
    end

    it "ignores non-string values so type checks stay with the callers" do
      expect { described_class.validate_fields!({ sync_collection_id: 84, retryable: true, observed_at: nil }) }
        .not_to raise_error
    end

    it "is a no-op for an empty field set" do
      expect { described_class.validate_fields!({}) }.not_to raise_error
    end
  end
end
