# frozen_string_literal: true

module Outbox
  # Deterministic run identifiers (RDR #215): every producer that references
  # a sync run — observation provenance, disappearance tombstones, and
  # sync-run summaries — must derive the same string so TaskBridge Web can
  # correlate item-level facts with run-level operational health:
  #
  #   sync-run-<compact UTC stamp of the run's start>-<service_type>
  #
  # The stamp comes from the run-scope `sync_started_at` option rather than
  # each producer's own clock, so every row produced during one service run
  # agrees even when producers run minutes apart.
  module SyncRunId
    module_function

    def for(service_type, started_at)
      "sync-run-#{started_at.utc.strftime('%Y%m%dT%H%M%SZ')}-#{service_type}"
    end
  end
end
