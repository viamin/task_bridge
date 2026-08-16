# frozen_string_literal: true

module Publication
  # Redacts secret-bearing fragments from operational text before it crosses
  # the publication boundary. This is intentionally conservative: free-text
  # diagnostics may keep surrounding context, but credential values, cookies,
  # and obvious secret assignments are replaced.
  module OperationalText
    module_function

    def sanitize(value)
      text = Utf8.sanitize(value)
      return text unless text.is_a?(String)

      redact_secret_assignments(redact_bearer_tokens(redact_header_values(text)))
    end

    def redact_header_values(text)
      text
        .gsub(/(authorization\s*:\s*)(?:bearer\s+)?[^\s,;]+/i, '\1[REDACTED]')
        .gsub(/(set-cookie\s*:\s*)[^\n]+/i, '\1[REDACTED]')
        .gsub(/(cookie\s*:\s*)[^\n]+/i, '\1[REDACTED]')
    end
    private_class_method :redact_header_values

    def redact_bearer_tokens(text)
      text.gsub(/\bBearer\s+\S+/i, "Bearer [REDACTED]")
    end
    private_class_method :redact_bearer_tokens

    def redact_secret_assignments(text)
      text.gsub(
        /\b(access[_-]?token|refresh[_-]?token|api[_-]?key|client[_-]?secret|password|passwd)\b(\s*[:=]\s*)([^\s,;]+)/i
      ) { "#{Regexp.last_match(1)}#{Regexp.last_match(2)}[REDACTED]" }
    end
    private_class_method :redact_secret_assignments
  end
end
