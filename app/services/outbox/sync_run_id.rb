# frozen_string_literal: true

module Outbox
  # Single source of truth for sync-run IDs (RDR #215), e.g.
  # "sync-run-20260814T192000Z-asana". The same run must carry the same
  # id everywhere it is referenced — sync-run summary rows, observation
  # provenance, and tombstone provenance — so TaskBridge Web can correlate
  # item-level facts with run-level operational health. The id is opaque:
  # consumers must not parse it by splitting on `:`.
  module SyncRunId
    module_function

    def for(service_name, at:)
      identifier = Base::Service.service_identifier_for(service_name)
      "sync-run-#{timestamp(at).utc.strftime('%Y%m%dT%H%M%SZ')}-#{identifier}"
    end

    # Callers hold either a Time (detector runs) or the ISO 8601 string the
    # sync task stores in options[:sync_started_at].
    def timestamp(at)
      return at if at.respond_to?(:utc)

      Time.iso8601(at.to_s)
    end
  end
end
