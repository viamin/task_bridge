# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::OperationalText do
  describe ".sanitize" do
    it "redacts bearer tokens in authorization headers" do
      text = "Authorization: Bearer <secret-token>"

      expect(described_class.sanitize(text)).to eq("[REDACTED]")
    end

    it "redacts case-insensitive authorization headers" do
      text = "authorization: bearer <secret-token>"

      expect(described_class.sanitize(text)).to eq("[REDACTED]")
    end

    it "redacts cookies" do
      text = "Cookie: <session-secret>"

      expect(described_class.sanitize(text)).to eq("[REDACTED]")
    end

    it "redacts set-cookie headers" do
      text = "set-cookie: <session-secret>"

      expect(described_class.sanitize(text)).to eq("[REDACTED]")
    end

    it "redacts basic auth credentials in authorization headers" do
      text = "Authorization: Basic dXNlcjpwYXNzd29yZA=="

      expect(described_class.sanitize(text)).to eq("[REDACTED]")
    end

    it "redacts digest auth credentials in authorization headers" do
      text = "Authorization: Digest dXNlcjpwYXNzd29yZA=="

      expect(described_class.sanitize(text)).to eq("[REDACTED]")
    end

    it "preserves the word 'basic' when it is not part of an authorization header" do
      text = "basic sync validation failed"

      expect(described_class.sanitize(text)).to eq(text)
    end

    it "redacts bearer tokens without a preceding keyword" do
      text = "bearer <token>"

      expect(described_class.sanitize(text)).to eq("[REDACTED]")
    end

    it "redacts access_token URL parameters" do
      text = "https://api.example.com/?access_token=<secret>"

      expect(described_class.sanitize(text)).to include("[REDACTED]")
      expect(described_class.sanitize(text)).not_to include("<secret>")
    end

    it "redacts refresh_token, api_key, client_secret, and password URL parameters" do
      %w[refresh_token api_key api-key client_secret password].each do |keyword|
        text = "#{keyword}=<secret>"
        sanitized = described_class.sanitize(text)

        expect(sanitized).to include("[REDACTED]")
        expect(sanitized).not_to include("<secret>")
      end
    end

    it "redacts colon-delimited credential fields from provider errors" do
      text = "X-Api-Key: <api-secret> accessToken: <access-secret> clientSecret: <client-secret>"

      sanitized = described_class.sanitize(text)

      expect(sanitized).to include("[REDACTED]")
      expect(sanitized).not_to include("<api-secret>", "<access-secret>", "<client-secret>")
    end

    it "redacts JSON-style credentials" do
      text = '{"access_token": "<secret>", "password": "<hunter2>"}'

      sanitized = described_class.sanitize(text)

      expect(sanitized).to include("[REDACTED]")
      expect(sanitized).not_to include("<secret>", "<hunter2>")
    end

    it "redacts raw provider response bodies" do
      text = "response: {\"items\": [{\"id\": 1}], \"count\": 2}"

      sanitized = described_class.sanitize(text)

      expect(sanitized).to include("[REDACTED]")
      expect(sanitized).not_to include("\"items\"", "\"count\"")
    end

    it "redacts payload and body literals" do
      %w[body payload response].each do |keyword|
        text = "#{keyword}: {\"id\": 1, \"value\": \"<secret>\"}"
        sanitized = described_class.sanitize(text)

        expect(sanitized).to include("[REDACTED]")
        expect(sanitized).not_to include("<secret>")
      end
    end

    it "redacts provider response bodies that span multiple lines" do
      text = "response: {\n  \"access_token\": \"<secret>\",\n  \"other\": \"data\"\n}"

      sanitized = described_class.sanitize(text)

      expect(sanitized).to include("[REDACTED]")
      expect(sanitized).not_to include("<secret>", "\"other\"", "\"data\"")
    end

    it "preserves text without sensitive content" do
      text = "sync failed after 12 items processed"

      expect(described_class.sanitize(text)).to eq(text)
    end

    it "coerces nil to an empty string" do
      expect(described_class.sanitize(nil)).to eq("")
    end

    it "coerces non-string values to strings before sanitizing" do
      expect(described_class.sanitize(42)).to eq("42")
      expect(described_class.sanitize("authorization: bearer <secret>")).to eq("[REDACTED]")
    end

    it "normalizes invalid UTF-8 before redacting untrusted provider text" do
      text = "\xFFtoken=<secret>".b

      sanitized = described_class.sanitize(text)

      expect(sanitized).to include("[REDACTED]")
      expect(sanitized).not_to include("<secret>")
      expect(sanitized.encoding).to eq(Encoding::UTF_8)
      expect(sanitized).to be_valid_encoding
    end

    it "redacts multiple sensitive patterns in the same string" do
      text = "Authorization: Bearer <token-1> cookie=<cookie-secret> access_token=<token-2>"

      sanitized = described_class.sanitize(text)

      expect(sanitized).not_to include("<token-1>", "<cookie-secret>", "<token-2>")
      expect(sanitized.scan("[REDACTED]").length).to be >= 3
    end

    it "is idempotent — re-sanitizing already-sanitized text is a no-op" do
      text = "Authorization: Bearer <secret>"

      first = described_class.sanitize(text)
      second = described_class.sanitize(first)

      expect(second).to eq(first)
    end
  end
end
