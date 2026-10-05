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
        observation_key(observed_at:, **identity)
      when "mapping"
        [PREFIX, "map", "sync_collection:#{identity.fetch(:sync_collection_id)}", "membership",
         identity.fetch(:service_instance), identity.fetch(:external_id), stamp(observed_at)].join(":")
      when "sync_run"
        [PREFIX, "sync_run", identity.fetch(:service_instance), identity.fetch(:sync_run_id)].join(":")
      else
        raise ArgumentError, "unknown record_kind: #{record_kind}"
      end
    end

    class << self
      private

      # RDR #215: when one observation yields several field transitions, each
      # row needs a distinct key, so a sequence segment is appended whenever
      # observed timestamps collide within one emission. Identity segments
      # are fetched (not declared as keywords) so a missing segment raises
      # KeyError, the enqueue contract's missing-identity signal.
      def observation_key(observed_at:, **identity)
        key = [PREFIX, "obs", identity.fetch(:service_instance), identity.fetch(:external_id),
               identity.fetch(:event_type), stamp(observed_at)].join(":")
        identity[:sequence] ? "#{key}:#{identity[:sequence]}" : key
      end

      def stamp(observed_at)
        observed_at.utc.iso8601(6)
      end
    end
  end
end
