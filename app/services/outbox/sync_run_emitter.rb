# frozen_string_literal: true

module Outbox
  # Emits `sync_run` summary rows (RDR #215) into the local outbox so
  # TaskBridge Web can correlate item observations with operational health.
  # One row per service run, built from the same StructuredLogger facts
  # SyncServiceState already persists — the contract's explicit `*_at`
  # timestamp names map directly onto the internal shorter keys.
  # Skipped or idle services publish nothing (RDR #215). Emission is
  # bookkeeping like every other outbox producer: wrapped in
  # Outbox::IsolatedWrite so a failed write never changes the run's own
  # result, and --pretend is enforced inside OutboxEntry.enqueue.
  class SyncRunEmitter
    PUBLISHABLE_STATUSES = %w[success failed].freeze
    DETAIL_LIMIT = 300

    def self.emit_for_run(summary, service_name:, started_at:, logs: [], finished_at: Time.current)
      new(summary, service_name:, started_at:, logs:, finished_at:).emit
    end

    def initialize(summary, service_name:, started_at:, logs:, finished_at:)
      @summary = summary.stringify_keys
      @service_name = service_name
      @started_at = started_at
      @logs = Array(logs).map(&:stringify_keys)
      @finished_at = finished_at
    end

    def emit
      return unless publishable?

      Outbox::IsolatedWrite.call("sync_run summary for #{sync_run_id}") do
        OutboxEntry.enqueue(record_kind: :sync_run, payload:, **enqueue_context)
      end
    end

    private

    attr_reader :summary, :service_name, :started_at, :logs, :finished_at

    def publishable?
      PUBLISHABLE_STATUSES.include?(summary["status"])
    end

    def payload
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        sync_run_id:,
        service_type:,
        service_instance:,
        started_at: timestamp(started_at),
        finished_at: timestamp(finished_at),
        last_attempted_at: timestamp(summary["last_attempted"] || started_at),
        last_successful_at: timestamp(summary["last_successful"]),
        last_failed_at: timestamp(summary["last_failed"]),
        status: summary["status"],
        items_synced: summary.fetch("items_synced", 0).to_i,
        touched_collection_ids:,
        detail: detail,
        # error is not valid when status is success (RDR #215).
        error: summary["status"] == "failed" ? error : nil
      }
    end

    def enqueue_context
      {
        service_type:,
        service_instance:,
        sync_run_id:,
        observed_at: finished_at
      }
    end

    # Mirrors Disappearance::Detector's run scope format
    # (sync-run-<timestamp>-<service>), e.g. "sync-run-20260814T192000Z-asana".
    def sync_run_id
      "sync-run-#{run_stamp}-#{service_type}"
    end

    def run_stamp
      parsed_start.utc.strftime("%Y%m%dT%H%M%SZ")
    end

    def parsed_start
      started_at.respond_to?(:utc) ? started_at : Time.zone.parse(started_at.to_s)
    end

    def service_type
      Base::Service.service_identifier_for(service_name)
    end

    def service_instance
      [service_type, Base::Service.instance_name_for(service_name)].compact.join(":")
    end

    def touched_collection_ids
      logs.flat_map { |log| Array(log["touched_collection_ids"]) }.compact.uniq
    end

    def detail
      summary["detail"].to_s.truncate(DETAIL_LIMIT).presence
    end

    # The run-level retry policy TaskBridge actually uses: every failed
    # service run is retried on the next scheduled sync (RDR #215 requires
    # error.retryable to match that outcome policy).
    def error
      failed_entry = logs.reverse.find { |log| log["error_class"].present? || log["error_message"].present? }
      {
        class: failed_entry&.[]("error_class").presence || "ProviderError",
        message: failed_entry&.[]("error_message").to_s.truncate(DETAIL_LIMIT).presence,
        retryable: true
      }
    end

    def timestamp(value)
      return if value.blank?

      parsed = value.respond_to?(:utc) ? value : Time.zone.parse(value.to_s)
      parsed&.utc&.iso8601(6)
    end
  end
end
