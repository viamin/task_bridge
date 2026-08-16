# frozen_string_literal: true

require "rails_helper"

RSpec.describe Publication::OperationalText do
  describe ".sanitize" do
    it "redacts authorization headers, cookies, bearer tokens, and token assignments" do
      text = <<~TEXT
        Authorization: Bearer top-secret
        Cookie: session=abc123
        access_token=xyz
        refresh_token: r1
      TEXT

      sanitized = described_class.sanitize(text)

      expect(sanitized).to include("Authorization: [REDACTED]")
      expect(sanitized).to include("Cookie: [REDACTED]")
      expect(sanitized).to include("refresh_token: [REDACTED]")
      expect(sanitized).not_to include("top-secret")
      expect(sanitized).not_to include("abc123")
      expect(sanitized).not_to include("xyz")
      expect(sanitized).not_to include("r1")
    end

    it "scrubs malformed UTF-8 before redacting" do
      text = (+"Bearer token-\xff").force_encoding("UTF-8")

      sanitized = described_class.sanitize(text)

      expect(sanitized).to eq("Bearer [REDACTED]")
      expect(sanitized).to be_valid_encoding
    end
  end
end
