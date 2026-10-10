# frozen_string_literal: true

module Outbox
  # Emits the per-service sync-run summary row (RDR #215 "Sync-Run Summary
  # Schema") into the local outbox so TaskBridge Web can correlate item
  # observations with operational health. Only `success` and `failed` runs
  # publish: skipped or idle services performed no run, and `partial` stays
  # reserved for runs that finish while some items fail. Like the other
  # emitters this is write-only bookkeeping wrapped in Outbox::IsolatedWrite
  # — an outbox failure can never change the run's own outcome — and
  # --pretend is enforced inside OutboxEntry.enqueue.
  class SyncRunEmitter
    PUBLISHABLE_STATUSES = %w[success failed].freeze
    TEXT_LIMIT = 300

    def self.emit_for_run(service:, summary:, logs:, sync_run_id:, started_at:)
      new(service:, summary:, logs:, sync_run_id:, started_at:).emit
    end

    def initialize(service:, summary:, logs:, sync_run_id:, started_at:)
      @service = service
      @summary = summary.is_a?(Hash) ? summary : {}
      @logs = Array(logs)
      @sync_run_id = sync_run_id
      @started_at = started_at
      @finished_at = Time.current
    end

    # Returns the enqueued OutboxEntry, nil when suppressed or dropped.
    def emit
      return unless publishable?

      Outbox::IsolatedWrite.call("sync-run summary for #{sync_run_id}") do
        OutboxEntry.enqueue(record_kind: :sync_run, payload:, **enqueue_context)
      end
    end

    private

    attr_reader :service, :summary, :logs, :sync_run_id, :started_at, :finished_at

    def publishable?
      sync_run_id.present? && service_name.present? &&
        PUBLISHABLE_STATUSES.include?(summary[:status].to_s)
    end

    def payload
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        sync_run_id:,
        service_type:,
        service_instance:,
        status: summary[:status].to_s,
        items_synced: summary[:items_synced].to_i
      }.merge(run_timestamps).merge(run_details)
    end

    def run_timestamps
      {
        started_at: iso_timestamp(started_at),
        finished_at: iso_timestamp(finished_at),
        last_attempted_at: iso_timestamp(summary[:last_attempted] || started_at),
        last_successful_at: iso_timestamp(summary[:last_successful]),
        last_failed_at: iso_timestamp(summary[:last_failed])
      }
    end

    def run_details
      {
        touched_collection_ids:,
        detail: summary[:detail].to_s.truncate(TEXT_LIMIT),
        error:
      }
    end

    # RDR #215: `error` is not valid when status is success, and
    # `error.retryable` must match the retry policy TaskBridge used — failed
    # runs retry on the next scheduled sync unless the service failed
    # authentication, which is terminal until its secrets are fixed.
    def error
      return unless summary[:status].to_s == "failed"

      entry = failure_entry
      {
        class: entry&.dig("error_class").presence || "unknown",
        message: (entry&.dig("error_message").presence || summary[:detail]).to_s.truncate(TEXT_LIMIT),
        retryable: !auth_failure?
      }
    end

    def failure_entry
      logs.reverse.find { |entry| entry["error_class"].present? || entry["error_message"].present? }
    end

    def auth_failure?
      service.respond_to?(:authorized) && service.authorized == false
    end

    def touched_collection_ids
      logs.flat_map { |entry| Array(entry["touched_collection_ids"]) }.uniq
    end

    def enqueue_context
      { service_type:, service_instance:, sync_run_id:, observed_at: finished_at }
    end

    def service_name
      return service.service_name if service.respond_to?(:service_name)

      service.friendly_name
    end

    def service_type
      Base::Service.service_identifier_for(Base::Service.class_name_for(service_name))
    end

    def service_instance
      [service_type, Base::Service.instance_name_for(service_name)].compact.join(":")
    end

    def iso_timestamp(value)
      time = coerce_time(value)
      time&.utc&.iso8601(6)
    end

    def coerce_time(value)
      return value if value.respond_to?(:utc)
      return if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
