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

    it "rejects strings whose bytes cannot be transcoded to UTF-8" do
      invalid = "\xE9".b

      expect do
        described_class.validate_fields!({ title: invalid })
      end.to raise_error(ArgumentError, /title must be valid UTF-8/)
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

  describe ".validate_structure!" do
    it "raises a valid UTF-8 error message when an invalid nested hash key is encountered" do
      invalid_key = (+"source\xff").force_encoding("UTF-8")

      expect do
        described_class.validate_structure!(:payload, { invalid_key => "ok" })
      end.to raise_error(ArgumentError) { |error|
        expect(error.message).to eq("payload.source\uFFFD(key) must be valid UTF-8")
        expect(error.message).to be_valid_encoding
      }
    end

    it "rejects nested strings whose bytes cannot be transcoded to UTF-8" do
      expect do
        described_class.validate_structure!(:payload, { source: { external_id: "\xE9".b } })
      end.to raise_error(ArgumentError, /payload\.source\.external_id must be valid UTF-8/)
    end
  end

  describe ".sanitize" do
    it "replaces malformed byte sequences with the replacement character" do
      expect(described_class.sanitize((+"milk \xff").force_encoding("UTF-8"))).to eq("milk \uFFFD")
    end

    it "leaves valid strings unchanged" do
      expect(described_class.sanitize("Buy milk — ünïcode")).to eq("Buy milk — ünïcode")
    end

    it "passes non-string values through untouched" do
      expect(described_class.sanitize(84)).to eq(84)
      expect(described_class.sanitize(nil)).to be_nil
      expect(described_class.sanitize(true)).to be true
    end
  end
end
