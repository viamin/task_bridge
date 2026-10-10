# frozen_string_literal: true

module Outbox
  # Emits one `sync_run` summary row (RDR #215) per service run so
  # TaskBridge Web can correlate item observations with operational health.
  # Only `success` and `failed` runs publish: skipped or idle services
  # performed no run, and `partial` is reserved for runs that finish while
  # some items fail (RDR #215). Emission is bookkeeping around sync —
  # wrapped in Outbox::IsolatedWrite so an outbox write failure never
  # changes the run outcome it describes.
  class SyncRunEmitter
    PUBLISHED_STATUSES = %w[success failed].freeze
    # `detail` and `error.message` are sanitized operational text (RDR
    # #215): bounded so a provider failure echoing a long payload cannot
    # balloon the row.
    TEXT_LIMIT = 300

    def self.emit_for_run(summary:, started_at:, finished_at:, error: nil, touched_collection_ids: [])
      service_name = summary.stringify_keys.fetch("service")
      Outbox::IsolatedWrite.call("sync run summary for #{service_name}") do
        new(summary:, started_at:, finished_at:, error:, touched_collection_ids:).emit
      end
    end

    def initialize(summary:, started_at:, finished_at:, error:, touched_collection_ids:)
      @summary = summary.stringify_keys
      @service_name = @summary.fetch("service").to_s
      @started_at = parse_timestamp(started_at)
      @finished_at = parse_timestamp(finished_at)
      @error = error
      @touched_collection_ids = Array(touched_collection_ids).compact.uniq
    end

    def emit
      return unless publishable?

      OutboxEntry.enqueue(record_kind: :sync_run, payload:, **enqueue_context)
    end

    private

    attr_reader :summary, :service_name, :started_at, :finished_at, :error, :touched_collection_ids

    def publishable?
      PUBLISHED_STATUSES.include?(summary["status"])
    end

    def payload
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        sync_run_id:,
        service_type:,
        service_instance:,
        started_at: iso_timestamp(started_at),
        finished_at: iso_timestamp(finished_at),
        last_attempted_at: iso_timestamp(summary_timestamp("last_attempted")),
        last_successful_at: iso_timestamp(summary_timestamp("last_successful")),
        last_failed_at: iso_timestamp(summary_timestamp("last_failed")),
        status: summary["status"],
        items_synced: summary.fetch("items_synced", 0).to_i,
        touched_collection_ids:,
        detail: truncated(summary["detail"])
      }.merge(error_payload)
    end

    # `error` is invalid when status is success (RDR #215); failed rows
    # carry the run's failure class and message. The scheduled sync
    # re-attempts every service on the next run, so failed run outcomes
    # are retryable under that policy.
    def error_payload
      return {} unless summary["status"] == "failed"

      details = error.is_a?(Hash) ? error : {}
      { error: { class: details["class"].presence, message: truncated(details["message"]),
                 retryable: true }.compact }
    end

    def enqueue_context
      { service_type:, service_instance:, sync_run_id:, observed_at: finished_at }
    end

    # Same shape as Disappearance::Detector run ids (RDR #215 example:
    # "sync-run-20260814T192000Z-asana"), derived from the run's start so
    # every emitter of one run derives the same identifier.
    def sync_run_id
      @sync_run_id ||= "sync-run-#{started_at.utc.strftime('%Y%m%dT%H%M%SZ')}-#{service_identifier}"
    end

    def service_type
      @service_type ||= Base::Service.service_identifier_for(Base::Service.class_name_for(service_name))
    end

    # Mirrors Outbox::SourceIdentity: adapter family plus configured
    # instance, so two accounts of one provider stay distinct.
    def service_instance
      @service_instance ||= [service_type, Base::Service.instance_name_for(service_name)].compact.join(":")
    end

    def service_identifier
      Base::Service.service_identifier_for(service_name)
    end

    def summary_timestamp(key)
      parse_timestamp(summary[key])
    end

    def parse_timestamp(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return if value.blank?

      Time.zone.parse(value.to_s)
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end

    def truncated(text)
      text.to_s.presence&.truncate(TEXT_LIMIT)
    end
  end
end
