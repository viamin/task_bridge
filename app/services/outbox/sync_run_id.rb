# frozen_string_literal: true

module Outbox
  # Canonical sync-run scope identifier (RDR #215):
  # "sync-run-<UTC compact timestamp>-<service_identifier>", e.g.
  # "sync-run-20260814T192000Z-asana". Shared by every producer that
  # correlates rows with a service run — observation provenance (#219),
  # tombstones (#220), and sync-run summaries (#221) — so TaskBridge Web
  # can group rows by run regardless of which producer emitted them.
  module SyncRunId
    TIME_FORMAT = "%Y%m%dT%H%M%SZ"

    class << self
      def for(service_name, at:)
        identifier = Base::Service.service_identifier_for(service_name)
        "sync-run-#{utc(at).strftime(TIME_FORMAT)}-#{identifier}"
      end

      private

      # Run scope comes from `options[:sync_started_at]` (an ISO 8601 string
      # in the rake task) or a Time object from direct emitters.
      def utc(value)
        parsed = value.is_a?(String) ? Time.zone.parse(value) : value
        parsed.utc
      end
    end
  end
end
