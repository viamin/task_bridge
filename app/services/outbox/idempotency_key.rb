# frozen_string_literal: true

module Outbox
  # Builds the deterministic record-level idempotency keys required by the
  # RDR #215 publication contract:
  #
  #   tb:v1:<record_kind>:<service_instance>:<external_id_or_scope>:<event_type_or_kind>:<observed_at_or_sequence>
  #
  # Keys are opaque: consumers must not parse them by splitting on `:`
  # because service instances, external IDs, and timestamps may themselves
  # contain colons. Different facts about the same item must use different
  # keys; retries of the same fact must reuse the same key.
  class IdempotencyKey
    PREFIX = "tb:v1"

    def self.for(record_kind:, observed_at:, **identity)
      case record_kind.to_s
      when "item"
        [PREFIX, "item", identity.fetch(:service_instance), identity.fetch(:external_id),
         "snapshot", stamp(observed_at)].join(":")
      when "observation"
        [PREFIX, "obs", identity.fetch(:service_instance), identity.fetch(:external_id),
         identity.fetch(:event_type), stamp(observed_at)].join(":")
      when "mapping"
        [PREFIX, "map", "sync_collection:#{identity.fetch(:sync_collection_id)}", "membership",
         identity.fetch(:service_instance), identity.fetch(:external_id), stamp(observed_at)].join(":")
      when "sync_run"
        [PREFIX, "sync_run", identity.fetch(:service_instance), identity.fetch(:sync_run_id)].join(":")
      else
        raise ArgumentError, "unknown record_kind: #{record_kind}"
      end
    end

    def self.stamp(observed_at)
      observed_at.utc.iso8601(6)
    end
    private_class_method :stamp
  end
end
