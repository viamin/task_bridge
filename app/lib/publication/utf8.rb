# frozen_string_literal: true

module Publication
  # Shared UTF-8 boundary guard for contract types.
  #
  # ActiveSupport's blank?/present? raise an opaque ArgumentError on strings
  # with malformed byte sequences, and such strings crash JSON generation
  # later in the outbox or publisher. Provider adapters can hand TaskBridge
  # those bytes (for example from AppleScript or provider HTTP responses),
  # so every caller-supplied string field is checked for a valid encoding
  # before any presence check runs.
  module Utf8
    module_function

    # Raises ArgumentError naming every field whose value is a string with an
    # invalid encoding. fields maps field names to caller-supplied values;
    # non-string values are ignored and left to the type checks.
    def validate_fields!(fields)
      invalid = fields.select { |_, value| value.is_a?(String) && !value.valid_encoding? }
      return if invalid.empty?

      raise ArgumentError, "#{invalid.keys.join(', ')} must be valid UTF-8"
    end
  end
end
