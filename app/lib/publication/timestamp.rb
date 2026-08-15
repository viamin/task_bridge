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
    def format(value)
      return if value.nil?

      time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
      time.utc.strftime(FORMAT)
    rescue ArgumentError => e
      raise ArgumentError, "invalid ISO 8601 timestamp #{value.inspect}: #{e.message}"
    end

    # Raises ArgumentError unless every provided value is nil or parseable.
    def validate!(*values)
      values.each { |value| format(value) }
    end
  end
end
