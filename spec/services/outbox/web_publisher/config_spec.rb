# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::WebPublisher::Config do
  describe ".resolve defaults" do
    it "is disabled by default with the documented defaults" do
      config = described_class.resolve

      expect(config.enabled?).to be(false)
      expect(config.dry_run?).to be(false)
      expect(config.batch_size).to eq(100)
      expect(config.timeout_seconds).to eq(30)
    end

    it "falls back to defaults when Chamber has no web settings" do
      allow(Chamber).to receive(:dig).with(:task_bridge, :web).and_return(nil)

      config = described_class.resolve

      expect(config.enabled?).to be(false)
      expect(config.batch_size).to eq(described_class::DEFAULT_BATCH_SIZE)
      expect(config.timeout_seconds).to eq(described_class::DEFAULT_TIMEOUT_SECONDS)
    end
  end

  describe "overrides" do
    it "wins over resolved settings and accepts symbol keys" do
      config = described_class.resolve(enabled: true, "base_url" => " https://web.example.com ",
                                       "api_key" => "key", "batch_size" => 25)

      expect(config.enabled?).to be(true)
      expect(config.base_url).to eq("https://web.example.com")
      expect(config.api_key).to eq("key")
      expect(config.batch_size).to eq(25)
    end

    it "clamps batch size to a positive integer and timeout to at least one second" do
      config = described_class.resolve("batch_size" => 0, "timeout_seconds" => -5)

      expect(config.batch_size).to eq(1)
      expect(config.timeout_seconds).to eq(1)
    end
  end

  describe "#uri" do
    it "parses http and https base URLs" do
      expect(described_class.resolve("base_url" => "https://web.example.com/tb").uri.to_s)
        .to eq("https://web.example.com/tb")
      expect(described_class.resolve("base_url" => "http://localhost:3000").uri.to_s)
        .to eq("http://localhost:3000")
    end

    it "returns nil for non-http schemes and malformed URLs" do
      expect(described_class.resolve("base_url" => "ftp://web.example.com").uri).to be_nil
      expect(described_class.resolve("base_url" => "not a url://").uri).to be_nil
      expect(described_class.resolve.uri).to be_nil
    end
  end

  describe "#incomplete?" do
    it "flags enabled runs that cannot send" do
      expect(described_class.resolve("enabled" => true).incomplete?).to be(true)
      expect(described_class.resolve("enabled" => true, "base_url" => "https://web.example.com").incomplete?).to be(true)
      expect(described_class.resolve("enabled" => true, "base_url" => "nope", "api_key" => "key").incomplete?).to be(true)
    end

    it "is false when disabled, dry-running, or fully configured" do
      expect(described_class.resolve.incomplete?).to be(false)
      expect(described_class.resolve("enabled" => true, "dry_run" => true).incomplete?).to be(false)
      expect(described_class.resolve("enabled" => true, "base_url" => "https://web.example.com",
                                     "api_key" => "key").incomplete?).to be(false)
    end
  end
end
