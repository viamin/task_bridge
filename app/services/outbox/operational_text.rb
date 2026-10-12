# frozen_string_literal: true

module Outbox
  # Removes credentials and provider response bodies from text that leaves the
  # local process as an operational summary. This is deliberately applied at
  # the publication boundary because provider error messages are untrusted.
  class OperationalText
    REDACTION = "[REDACTED]"
    REDACTIONS = [
      /\bauthorization\s*[:=]\s*digest\s+[^\r\n]*/i,
      /\b(?:cookie|set-cookie)\s*:\s*[^\r\n]*/i,
      /\b(?:authorization|cookie|set-cookie)\s*[:=]\s*(?:(?:bearer|basic|digest)\s+)?[^\s,;]+/i,
      /["'](?:authorization|cookie|set-cookie)["']\s*=>\s*(?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|[^,\s}]+)/i,
      /\b(?:(?:access|refresh)[_-]?token|api[_-]?key|client[_-]?secret|password|token)\s*[:=]\s*[^&\s,]+/i,
      /["'](?:access_?token|refresh_?token|token|api[_-]?key|authorization|cookie|password)["']\s*:\s*["'][^"']*["']/i,
      /\bbearer\s+[^\s,;]+/i
    ].freeze
    STRUCTURED_BODY_PREFIX = /\b(?:body|payload|response)\b["']?\s*(?:[:=]|=>)\s*(?=[{\[])/i
    OPENING_DELIMITERS = ["{", "["].freeze
    QUOTES = ['"', "'"].freeze

    def self.sanitize(value)
      REDACTIONS.reduce(redact_structured_bodies(normalized_text(value))) do |text, pattern|
        text.gsub(pattern, REDACTION)
      end
    end

    def self.normalized_text(value)
      value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
    end
    private_class_method :normalized_text

    def self.redact_structured_bodies(text)
      output = +""
      cursor = 0

      while (match = STRUCTURED_BODY_PREFIX.match(text, cursor))
        literal_start = match.end(0)
        literal_end = structured_literal_end(text, literal_start) || text.length
        output << text[cursor...literal_start] << REDACTION
        cursor = literal_end
      end

      output << text[cursor..]
    end
    private_class_method :redact_structured_bodies

    def self.structured_literal_end(text, start)
      delimiters = [text[start]]
      quote = nil
      escaped = false

      ((start + 1)...text.length).each do |index|
        character = text[index]
        quote, escaped = quoted_literal_state(character, quote, escaped)
        next if quote

        delimiters << character if OPENING_DELIMITERS.include?(character)
        delimiters.pop if closes_delimiter?(character, delimiters.last)
        return index + 1 if delimiters.empty?
      end
    end
    private_class_method :structured_literal_end

    def self.quoted_literal_state(character, quote, escaped)
      return [character, false] if quote.nil? && QUOTES.include?(character)
      return [quote, false] if escaped
      return [quote, true] if quote && character == "\\"
      return [nil, false] if quote == character

      [quote, false]
    end
    private_class_method :quoted_literal_state

    def self.closes_delimiter?(character, delimiter)
      (character == "}" && delimiter == "{") || (character == "]" && delimiter == "[")
    end
    private_class_method :closes_delimiter?
  end
end
