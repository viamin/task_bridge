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

    # Raises ArgumentError naming every invalid UTF-8 string nested inside
    # value. Hash keys are checked too because malformed string keys also break
    # JSON generation later in the outbox.
    def validate_structure!(field_name, value)
      invalid = []
      collect_invalid_paths(value, field_name.to_s, invalid)
      return if invalid.empty?

      raise ArgumentError, "#{invalid.join(', ')} must be valid UTF-8"
    end

    # Returns value with malformed byte sequences replaced by U+FFFD so remote
    # text can never crash logging, validation, or JSON generation downstream.
    # Non-string values pass through untouched. Use for external text that is
    # informational (error messages, codes) rather than contract identity,
    # which must be rejected, not repaired, via validate_fields!.
    def sanitize(value)
      return value unless value.is_a?(String)

      value.scrub
    end

    def collect_invalid_paths(value, path, invalid)
      case value
      when String
        invalid << path unless value.valid_encoding?
      when Array
        value.each_with_index do |item, index|
          collect_invalid_paths(item, "#{path}[#{index}]", invalid)
        end
      when Hash
        value.each do |key, nested|
          key_path = "#{path}.#{key}"
          invalid << "#{key_path}(key)" if key.is_a?(String) && !key.valid_encoding?
          collect_invalid_paths(nested, key_path, invalid)
        end
      end
    end
    private_class_method :collect_invalid_paths
  end
end
