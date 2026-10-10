# frozen_string_literal: true

module Outbox
  # Publishes one sync-run summary row per service run (RDR #215
  # "Sync-Run Summary Schema") so TaskBridge Web can correlate item
  # observations with operational health. The row is derived from the same
  # StructuredLogger run summary the sync task already persists through
  # SyncServiceState, so publication adds no new truth — only a durable
  # fact for TaskBridge Web. Emission is write-only bookkeeping wrapped in
  # Outbox::IsolatedWrite: a failed outbox write is reported and superseded
  # by the next run's row, never by the sync result. Skipped and idle
  # services publish nothing (RDR #215).
  class SyncRunEmitter
    # `partial` is reserved by the contract for runs that finish while some
    # items fail; TaskBridge only records success and failed runs today.
    PUBLISHABLE_STATUSES = %w[success failed].freeze
    DETAIL_LIMIT = 300
    SYNC_RUN_TIMESTAMP_FORMAT = "%Y%m%dT%H%M%SZ"

    def self.emit_for_run(summary:, logs:, service_name:, started_at:, finished_at: Time.current)
      new(summary:, logs:, service_name:, started_at:, finished_at:).emit
    end

    def initialize(summary:, logs:, service_name:, started_at:, finished_at:)
      @summary = summary.stringify_keys
      @logs = Array(logs).map(&:stringify_keys)
      @service_name = service_name
      @started_at = parse_timestamp(started_at)
      @finished_at = parse_timestamp(finished_at)
    end

    def emit
      return unless publishable?

      Outbox::IsolatedWrite.call("sync run summary for #{sync_run_id}") do
        OutboxEntry.enqueue(record_kind: :sync_run, payload:, **enqueue_context)
      end
    end

    private

    attr_reader :summary, :logs, :service_name, :started_at, :finished_at

    def publishable?
      PUBLISHABLE_STATUSES.include?(summary["status"].to_s) && started_at.present?
    end

    def enqueue_context
      { service_type:, service_instance:, sync_run_id:, observed_at: finished_at }
    end

    def payload
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        sync_run_id:,
        service_type:,
        service_instance:,
        started_at: iso_timestamp(started_at),
        finished_at: iso_timestamp(finished_at),
        last_attempted_at: iso_timestamp(attempted_at),
        last_successful_at: iso_timestamp(parse_timestamp(summary["last_successful"])),
        last_failed_at: iso_timestamp(parse_timestamp(summary["last_failed"])),
        status: summary["status"],
        items_synced: summary.fetch("items_synced", 0).to_i,
        touched_collection_ids:,
        detail:,
        error:
      }
    end

    # RDR #215 sync-run scope, e.g. "sync-run-20260814T192000Z-asana", the
    # same format Disappearance::Detector derives per service per run.
    def sync_run_id
      "sync-run-#{started_at.utc.strftime(SYNC_RUN_TIMESTAMP_FORMAT)}-#{service_type}"
    end

    def service_type
      Base::Service.service_identifier_for(Base::Service.class_name_for(service_name))
    end

    # Matches the vocabulary Outbox::SourceIdentity publishes for items of
    # this service instance (e.g. "asana:work").
    def service_instance
      [service_type, Base::Service.instance_name_for(service_name)].compact.join(":")
    end

    def attempted_at
      parse_timestamp(summary["last_attempted"]) || started_at
    end

    def touched_collection_ids
      logs.flat_map { |entry| Array(entry["touched_collection_ids"]) }.compact.uniq
    end

    # Operational text only (RDR #215): detail comes from the run summary's
    # counts and error class/message lines; truncation bounds whatever a
    # provider error embedded.
    def detail
      truncate(summary["detail"])
    end

    def error
      return unless summary["status"] == "failed"

      failed_entry = logs.reverse.find { |entry| entry["error_class"].present? || entry["error_message"].present? }
      {
        class: failed_entry&.[]("error_class").presence || "UnknownError",
        message: truncate(failed_entry&.[]("error_message").presence || summary["detail"]),
        # TaskBridge retries service runs on the next scheduled sync, so a
        # failed run summary describes a retryable outcome (RDR #215).
        retryable: true
      }
    end

    def truncate(text)
      text.to_s.presence&.truncate(DETAIL_LIMIT)
    end

    def parse_timestamp(value)
      return if value.blank?
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

      Time.zone.parse(value.to_s)
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
