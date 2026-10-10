# frozen_string_literal: true

module Outbox
  # Emits `sync_run` summary rows (RDR #215) into the local outbox so
  # TaskBridge Web can correlate item observations with operational health.
  # Skipped and idle services publish nothing; failed runs publish their
  # error. Like the other emitters this is bookkeeping around sync, wrapped
  # in Outbox::IsolatedWrite so an outbox write failure can never change the
  # sync outcome it records.
  #
  # `summary` is the run summary hash from
  # StructuredLogger#summarize_service_run, enriched by the caller with the
  # run's `touched_collection_ids` and, for failed runs, a structured
  # `error` ({class:, message:, retryable:}).
  class SyncRunEmitter
    PUBLISHED_STATUSES = %w[success failed partial].freeze

    def self.emit_for(service_name:, summary:, started_at:, finished_at:)
      Outbox::IsolatedWrite.call("sync_run summary for #{service_name}") do
        new(service_name:, summary:, started_at:, finished_at:).emit
      end
    end

    def initialize(service_name:, summary:, started_at:, finished_at:)
      @service_name = service_name
      @summary = summary.stringify_keys
      @started_at = coerce_time(started_at)
      @finished_at = coerce_time(finished_at)
    end

    def emit
      return unless publishable?

      OutboxEntry.enqueue(record_kind: :sync_run, payload:, **enqueue_context)
    end

    private

    attr_reader :service_name, :summary, :started_at, :finished_at

    def publishable?
      started_at.present? && finished_at.present? && PUBLISHED_STATUSES.include?(summary["status"].to_s)
    end

    def enqueue_context
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        sync_run_id:,
        observed_at: finished_at
      }
    end

    def payload
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        sync_run_id:,
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        started_at: iso_timestamp(started_at),
        finished_at: iso_timestamp(finished_at),
        last_attempted_at: iso_timestamp(attempted_at),
        last_successful_at: iso_timestamp(summary_time("last_successful")),
        last_failed_at: iso_timestamp(summary_time("last_failed")),
        status: summary["status"],
        items_synced: summary.fetch("items_synced", 0).to_i,
        touched_collection_ids: Array(summary["touched_collection_ids"]).compact.uniq,
        detail: summary["detail"].presence,
        error: error_payload
      }
    end

    # Matches the run id ObservationEmitter records in observation
    # provenance ("sync-run-#{options[:sync_started_at]}"), so rows from
    # the same run correlate downstream.
    def sync_run_id
      "sync-run-#{iso_timestamp(started_at)}"
    end

    def identity
      @identity ||= Outbox::SourceIdentity.for_service_name(service_name)
    end

    # RDR #215: `error` is not valid when `status` is `success`.
    def error_payload
      error = summary["error"]
      return nil if summary["status"] == "success"
      return nil unless error.is_a?(Hash)

      {
        "class" => error[:class] || error["class"],
        "message" => error[:message] || error["message"],
        # Sync runs are not automatically retried — publication retries are
        # row-level — so run errors report as terminal.
        "retryable" => false
      }.compact
    end

    def attempted_at
      summary_time("last_attempted") || started_at
    end

    def summary_time(key)
      value = summary[key]
      value.present? ? coerce_time(value) : nil
    end

    def coerce_time(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

      Time.zone.parse(value.to_s)
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
