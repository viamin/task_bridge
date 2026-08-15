# frozen_string_literal: true

module Publication
  # Canonical timestamp handling for the v1 contract.
  #
  # All published timestamps must be ISO 8601 UTC with microseconds when
  # available. String inputs are parsed and re-emitted in canonical form so the
  # same instant always serializes to the same string (and therefore produces
  # the same idempotency key). Values that cannot be parsed raise ArgumentError
  # at the boundary instead of producing malformed payloads downstream.
  module Timestamp
    FORMAT = "%Y-%m-%dT%H:%M:%S.%6NZ"

    module_function

    # Returns the canonical UTC serialization of value, or nil when value is nil.
    # ActiveSupport::TimeWithZone subclasses Time on Rails 7.1+, so zoned times
    # (for example Time.current with Time.zone set) take the direct path.
    def format(value)
      return if value.nil?

      time = value.is_a?(Time) ? value : parse_string(value)
      time.utc.strftime(FORMAT)
    rescue ArgumentError => e
      raise ArgumentError, "invalid ISO 8601 timestamp #{value.inspect}: #{e.message}"
    end

    # Raises ArgumentError unless every provided value is nil or parseable.
    def validate!(*values)
      values.each { |value| format(value) }
    end

    # Zone-less strings would be interpreted in the system's local timezone,
    # silently producing machine-dependent instants (and therefore unstable
    # idempotency keys on hosts outside UTC). The contract requires a UTC
    # designator or an explicit numeric offset, so ambiguous inputs are
    # rejected instead of guessed.
    def parse_string(value)
      string = value.to_s
      parts = Date._iso8601(string)
      raise ArgumentError, "missing timezone: UTC 'Z' or a numeric offset is required" if parts.key?(:year) && parts[:zone].nil?

      Time.iso8601(string)
    end
  end
end
