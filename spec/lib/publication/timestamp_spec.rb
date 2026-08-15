# frozen_string_literal: true

require "rails_helper"

RSpec.describe Publication::Timestamp do
  describe ".format" do
    it "returns nil for nil" do
      expect(described_class.format(nil)).to be_nil
    end

    it "formats a Time value as ISO 8601 UTC with microseconds" do
      time = Time.utc(2026, 8, 14, 19, 20, 31, 123_456)
      expect(described_class.format(time)).to eq("2026-08-14T19:20:31.123456Z")
    end

    it "converts a local Time to UTC" do
      local = Time.new(2026, 8, 14, 21, 20, 31, "+02:00")
      expect(described_class.format(local)).to eq("2026-08-14T19:20:31.000000Z")
    end

    it "formats an ActiveSupport::TimeWithZone to UTC" do
      zone = ActiveSupport::TimeZone.new("Kathmandu") # UTC+05:45
      zoned = zone.local(2026, 8, 15, 1, 5, 31, 123_456) # 2026-08-14T19:20:31.123456Z
      expect(described_class.format(zoned)).to eq("2026-08-14T19:20:31.123456Z")
    end

    it "produces the same output for a zoned time and its equivalent Time" do
      zone = ActiveSupport::TimeZone.new("Kathmandu")
      zoned = zone.local(2026, 8, 15, 1, 5, 31)
      expect(described_class.format(zoned)).to eq(described_class.format(Time.utc(2026, 8, 14, 19, 20, 31)))
    end

    it "passes through a canonical timestamp string unchanged" do
      expect(described_class.format("2026-08-14T19:20:31.123456Z")).to eq("2026-08-14T19:20:31.123456Z")
    end

    it "normalizes a timestamp string without microseconds" do
      expect(described_class.format("2026-08-14T19:20:31Z")).to eq("2026-08-14T19:20:31.000000Z")
    end

    it "normalizes a timestamp string with a UTC offset" do
      expect(described_class.format("2026-08-14T21:20:31+02:00")).to eq("2026-08-14T19:20:31.000000Z")
    end

    it "produces the same output for a Time and its equivalent string" do
      time = Time.utc(2026, 8, 14, 19, 20, 31, 123_456)
      expect(described_class.format(time)).to eq(described_class.format("2026-08-14T19:20:31.123456Z"))
    end

    it "raises ArgumentError for an unparseable string" do
      expect { described_class.format("not-a-timestamp") }
        .to raise_error(ArgumentError, /invalid ISO 8601 timestamp/)
    end

    it "raises ArgumentError for a blank string" do
      expect { described_class.format("") }
        .to raise_error(ArgumentError, /invalid ISO 8601 timestamp/)
    end
  end

  describe ".validate!" do
    it "accepts nil values" do
      expect { described_class.validate!(nil, nil) }.not_to raise_error
    end

    it "accepts parseable values" do
      expect { described_class.validate!("2026-08-14T19:20:31Z", Time.current) }.not_to raise_error
    end

    it "raises ArgumentError when any value is unparseable" do
      expect { described_class.validate!("2026-08-14T19:20:31Z", "garbage") }
        .to raise_error(ArgumentError, /invalid ISO 8601 timestamp/)
    end
  end
end
