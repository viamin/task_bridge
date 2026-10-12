# frozen_string_literal: true

module Outbox
  # Removes credentials and provider response bodies from text that leaves the
  # local process as an operational summary. This is deliberately applied at
  # the publication boundary because provider error messages are untrusted.
  class OperationalText
    REDACTION = "[REDACTED]"
    REDACTIONS = [
      /\b(?:authorization|cookie|set-cookie)\s*[:=]\s*(?:(?:bearer|basic|digest)\s+)?[^\s,;]+/i,
      /\b(?:(?:access|refresh)[_-]?token|api[_-]?key|client[_-]?secret|password|token)\s*[:=]\s*[^&\s,]+/i,
      /["'](?:access_?token|refresh_?token|token|api[_-]?key|authorization|cookie|password)["']\s*:\s*["'][^"']*["']/i,
      /\bbearer\s+[^\s,;]+/i,
      /\b(?:body|payload|response)\s*[:=]\s*(?:\{[^\n]*\}|\[[^\n]*\])/i
    ].freeze

    def self.sanitize(value)
      REDACTIONS.reduce(normalized_text(value)) { |text, pattern| text.gsub(pattern, REDACTION) }
    end

    def self.normalized_text(value)
      value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
    end
    private_class_method :normalized_text
  end
end
