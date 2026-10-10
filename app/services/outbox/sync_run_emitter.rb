# frozen_string_literal: true

module Outbox
  # Emits one `sync_run` summary row (RDR #215 "Sync-Run Summary Schema")
  # into the local outbox per service run so TaskBridge Web can correlate
  # item observations with operational health. Skipped and idle services
  # publish nothing. Like every outbox producer this is write-only
  # bookkeeping: the enqueue is wrapped in Outbox::IsolatedWrite so a
  # transient write failure never changes the run result it records, and
  # pretend runs never enqueue rows (enforced by OutboxEntry.enqueue).
  class SyncRunEmitter
    PUBLISHED_STATUSES = %w[success failed].freeze
    DETAIL_LIMIT = 1_000
    # Detail and error messages come from provider exception handling;
    # credential-shaped fragments must never reach TaskBridge Web
    # (RDR #215 security constraints). Matches the credential scheme plus
    # its token, e.g. "Authorization: Bearer <token>" or "Bearer <token>".
    CREDENTIAL_PATTERN = /\b(?:authorization\s*:\s*|bearer\s+)(?:\S+\s+)?\S+/i

    def self.emit_service_run(service_name:, summary:, logs:, started_at:, finished_at: Time.current)
      Outbox::IsolatedWrite.call("sync run summary for #{service_name}") do
        new(service_name:, summary:, logs:, started_at:, finished_at:).emit
      end
    end

    def initialize(service_name:, summary:, logs:, started_at:, finished_at:)
      @service_name = service_name.to_s
      @summary = summary.stringify_keys
      @logs = Array(logs).compact
      @started_at = parse_time(started_at)
      @finished_at = parse_time(finished_at) || Time.current
    end

    def emit
      return unless publishable?

      OutboxEntry.enqueue(record_kind: :sync_run, payload:, **enqueue_context)
    end

    private

    attr_reader :service_name, :summary, :logs, :started_at, :finished_at

    def publishable?
      PUBLISHED_STATUSES.include?(summary["status"]) && started_at.present?
    end

    def enqueue_context
      {
        service_type: service_type,
        service_instance: service_instance,
        sync_run_id: sync_run_id,
        observed_at: started_at
      }
    end

    def payload
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        sync_run_id: sync_run_id,
        service_type: service_type,
        service_instance: service_instance,
        started_at: timestamp(started_at),
        finished_at: timestamp(finished_at),
        last_attempted_at: timestamp(summary["last_attempted"]) || timestamp(started_at),
        last_successful_at: timestamp(summary["last_successful"]),
        last_failed_at: timestamp(summary["last_failed"]),
        status: summary["status"],
        items_synced: summary.fetch("items_synced", 0).to_i,
        touched_collection_ids: touched_collection_ids,
        detail: sanitize(summary["detail"]),
        error: error
      }
    end

    # RDR #215 sync-run scope, e.g. "sync-run-20260814T192000Z-asana",
    # matching the format Disappearance::Detector derives per run.
    def sync_run_id
      identifier = Base::Service.service_identifier_for(service_name)
      "sync-run-#{started_at.utc.strftime('%Y%m%dT%H%M%SZ')}-#{identifier}"
    end

    # Same identity shape as Outbox::SourceIdentity so sync_run rows and
    # item-scoped rows agree on how a service is identified.
    def service_type
      Base::Service.service_identifier_for(Base::Service.class_name_for(service_name))
    end

    def service_instance
      [service_type, Base::Service.instance_name_for(service_name)].compact.join(":")
    end

    def touched_collection_ids
      logs.flat_map { |entry| Array(entry["touched_collection_ids"] || entry[:touched_collection_ids]) }.compact.uniq
    end

    # `error` is not valid when status is success (RDR #215); retryable
    # reflects the run-level retry policy TaskBridge actually uses: a
    # failed service is isolated and re-attempted on the next scheduled
    # sync run.
    def error
      return unless summary["status"] == "failed"

      failed_entry = logs.reverse.find { |entry| entry["error_message"].present? || entry["error_class"].present? }
      {
        class: failed_entry&.[]("error_class").presence || "ProviderError",
        message: sanitize(failed_entry&.[]("error_message")),
        retryable: true
      }
    end

    def sanitize(text)
      return if text.blank?

      text.to_s.gsub(CREDENTIAL_PATTERN, "[redacted]")
          .gsub(/\s+/, " ")
          .strip
          .truncate(DETAIL_LIMIT)
    end

    def timestamp(value)
      parse_time(value)&.utc&.iso8601(6)
    end

    def parse_time(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return if value.blank?

      Time.zone.parse(value.to_s)
    end
  end
end
