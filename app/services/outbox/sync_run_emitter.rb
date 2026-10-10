# frozen_string_literal: true

module Outbox
  # Emits `sync_run` rows (RDR #215 Sync-Run Summary Schema) into the local
  # outbox so TaskBridge Web can correlate item observations with run-level
  # operational health. One row per service run; skipped or idle services
  # publish nothing. Like the other emitters this is bookkeeping around sync:
  # callers wrap it in Outbox::IsolatedWrite so an outbox hiccup never
  # changes the sync outcome, and --pretend is enforced inside
  # OutboxEntry.enqueue.
  class SyncRunEmitter
    PUBLISHABLE_STATUSES = %w[success failed].freeze
    DETAIL_LIMIT = 1_000

    # `summary` is the StructuredLogger#summarize_service_run hash for one
    # service's portion of a run; `logs` are the per-strategy log entries it
    # was summarized from (error provenance, touched collections). The run
    # scope for the idempotency key comes from the summary's
    # `last_attempted`, which every log path stamps with the run-scope
    # `sync_started_at` — the same source observation provenance uses.
    def self.emit_for_run(service_name:, summary:, logs:, finished_at: Time.current)
      new(service_name:, summary:, logs:, finished_at:).emit
    end

    def initialize(service_name:, summary:, logs:, finished_at:)
      @service_name = service_name.to_s
      @summary = summary.stringify_keys
      @logs = Array(logs).map(&:stringify_keys)
      @finished_at = finished_at
    end

    def emit
      return unless publishable? && started_at.present?

      OutboxEntry.enqueue(
        record_kind: :sync_run,
        payload:,
        service_type:,
        service_instance:,
        sync_run_id:,
        observed_at: finished_at
      )
    end

    private

    attr_reader :service_name, :summary, :logs, :finished_at

    def publishable?
      PUBLISHABLE_STATUSES.include?(summary["status"])
    end

    # Present for every publishable summary: each log path that produces a
    # success or failed status stamps last_attempted with the run start.
    def started_at
      summary["last_attempted"].presence
    end

    def service_type
      @service_type ||= Base::Service.service_identifier_for(
        Base::Service.class_name_for(service_name)
      )
    end

    # Same construction as Outbox::SourceIdentity so run rows and item rows
    # agree on how a service instance is written.
    def service_instance
      [service_type, Base::Service.instance_name_for(service_name)].compact.join(":")
    end

    def sync_run_id
      @sync_run_id ||= Outbox::SyncRunId.for(service_type, Time.zone.parse(started_at))
    end

    def payload
      # Explicit nulls match the RDR example: consumers can rely on the
      # timestamp and error keys being present rather than distinguishing
      # omission from null.
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        sync_run_id:,
        service_type:,
        service_instance:,
        started_at: timestamp(started_at),
        finished_at: timestamp(finished_at),
        last_attempted_at: timestamp(started_at),
        last_successful_at: timestamp(summary["last_successful"]),
        last_failed_at: timestamp(summary["last_failed"]),
        status: summary["status"],
        items_synced: summary["items_synced"].to_i,
        touched_collection_ids: touched_collection_ids,
        detail: summary["detail"].to_s.truncate(DETAIL_LIMIT).presence,
        error:
      }
    end

    def touched_collection_ids
      logs.flat_map { |entry| Array(entry["touched_collection_ids"] || entry[:touched_collection_ids]) }
          .compact.uniq
    end

    def error
      return nil unless summary["status"] == "failed"

      failed_entry = logs.reverse.find do |entry|
        entry["error_class"].present? || entry["error_message"].present?
      end
      {
        class: failed_entry&.[]("error_class").presence || "ProviderError",
        message: (failed_entry&.[]("error_message").presence || summary["detail"]).to_s.truncate(DETAIL_LIMIT),
        # TaskBridge retries every service on the next scheduled run, so run
        # failures stay retryable at the run level (RDR: error.retryable must
        # match the retry policy used for the run outcome).
        retryable: true
      }
    end

    def timestamp(value)
      return if value.blank?

      Time.zone.parse(value.to_s)&.utc&.iso8601(6)
    end
  end
end
