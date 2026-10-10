# frozen_string_literal: true

module Outbox
  # Builds the shared run-scope identifier that everything one sync run
  # publishes is stamped with (RDR #215): "sync-run-<compact UTC
  # timestamp>-<service identifier>", e.g. "sync-run-20260814T192000Z-asana".
  # Observation provenance, tombstones, and sync-run summaries all derive
  # the id from the same run-scoped timestamp (`options[:sync_started_at]`)
  # so TaskBridge Web can correlate rows from one run.
  module SyncRunId
    TIMESTAMP_FORMAT = "%Y%m%dT%H%M%SZ"

    module_function

    def for(service_name, at:)
      timestamp = parse(at)
      return if timestamp.blank?

      "sync-run-#{timestamp.utc.strftime(TIMESTAMP_FORMAT)}-#{Base::Service.service_identifier_for(service_name)}"
    end

    # Accepts Times (or time-like values) and parseable timestamp strings;
    # blank or unparseable input yields nil so callers can omit the fact.
    def parse(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return if value.to_s.blank?

      Time.zone.parse(value.to_s)
    end
  end
end
