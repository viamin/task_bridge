# frozen_string_literal: true

module Outbox
  # Publishes one sync-run summary row per service run (RDR #215 Sync-Run
  # Summary Schema) so TaskBridge Web can correlate item observations with
  # operational health. Only `success` and `failed` runs publish: skipped
  # or idle services performed no run, and `partial` is reserved for runs
  # that finish while some items fail, which TaskBridge does not produce.
  #
  # Emission is bookkeeping after the run, wrapped in Outbox::IsolatedWrite:
  # a failed outbox write is reported and re-emitted by the next run, never
  # changing the run's own outcome. Pretend runs enqueue nothing
  # (OutboxEntry.enqueue strict no-op).
  class SyncRunEmitter
    EMITTED_STATUSES = %w[success failed].freeze

    def self.emit_for(service_name:, summary:, logs:, now: Time.current)
      summary = summary.stringify_keys
      return unless summary["status"].in?(EMITTED_STATUSES)

      Outbox::IsolatedWrite.call("sync run for #{service_name}") do
        new(service_name:, summary:, logs:, now:).emit
      end
    end

    def initialize(service_name:, summary:, logs:, now:)
      @service_name = service_name
      @summary = summary
      @logs = Array(logs)
      @now = now
    end

    def emit
      OutboxEntry.enqueue(record_kind: :sync_run, payload:, **enqueue_context)
    end

    private

    attr_reader :service_name, :summary, :logs, :now

    def payload
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        sync_run_id:,
        service_type:,
        service_instance:,
        started_at: iso(started_at),
        finished_at: iso(now),
        last_attempted_at: iso(started_at),
        status: summary["status"],
        items_synced: summary["items_synced"].to_i,
        touched_collection_ids:,
        detail: summary["detail"].presence,
        last_successful_at: iso(summary["last_successful"]),
        last_failed_at: iso(summary["last_failed"]),
        error:
      }.compact
    end

    def enqueue_context
      { service_type:, service_instance:, sync_run_id:, observed_at: now }
    end

    # The run scope every log stamps as last_attempted
    # (options[:sync_started_at]); when a producer omitted it, the
    # conclusion time is the closest honest value, and the idempotency key
    # still derives from the same timestamp so the row stays deterministic.
    def started_at
      Outbox::SyncRunId.parse(summary["last_attempted"]) || now
    end

    def sync_run_id
      Outbox::SyncRunId.for(service_name, at: started_at)
    end

    def service_type
      Base::Service.service_identifier_for(Base::Service.class_name_for(service_name))
    end

    # Mirrors Outbox::SourceIdentity's instance shape so a run is identified
    # like the items it observed: adapter family plus configured instance.
    def service_instance
      [service_type, Base::Service.instance_name_for(service_name)].compact.join(":")
    end

    def touched_collection_ids
      logs.flat_map { |entry| Array(entry["touched_collection_ids"]) }.uniq
    end

    def error
      return if summary["status"] == "success"

      failed_entry = logs.reverse.find { |entry| entry["error_class"].present? || entry["error_message"].present? }
      return unless failed_entry

      {
        class: failed_entry["error_class"].presence,
        message: failed_entry["error_message"].presence,
        # TaskBridge does not automatically retry failed service runs — the
        # next scheduled run is a new run — so the outcome is terminal
        # (RDR #215: error.retryable must match the retry policy used).
        retryable: false
      }.compact
    end

    def iso(value)
      Outbox::SyncRunId.parse(value)&.utc&.iso8601(6)
    end
  end
end
