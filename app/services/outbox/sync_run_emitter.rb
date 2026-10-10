# frozen_string_literal: true

module Outbox
  # Emits one `sync_run` summary row (RDR #215) per service run so
  # TaskBridge Web can correlate item observations with operational health.
  # A row is only enqueued for runs this invocation actually attempted: a
  # skipped service replays its previous state (stale `last_attempted`), and
  # the RDR forbids publishing summaries for skipped or idle services.
  # Emission is bookkeeping — an outbox write failure is isolated and never
  # changes the recorded sync outcome.
  class SyncRunEmitter
    PUBLISHED_STATUSES = %w[success failed].freeze

    def self.emit_for_run(summary, logs:, sync_started_at:, finished_at: Time.current)
      new(summary, logs:, sync_started_at:, finished_at:).emit
    end

    def initialize(summary, logs:, sync_started_at:, finished_at:)
      @summary = summary.stringify_keys
      @logs = Array(logs)
      @sync_started_at = sync_started_at
      @finished_at = finished_at
    end

    def emit
      return unless publishable?

      Outbox::IsolatedWrite.call("sync run for #{service_instance}") do
        OutboxEntry.enqueue(record_kind: :sync_run, payload:, **enqueue_context)
      end
    end

    private

    attr_reader :summary, :logs, :sync_started_at, :finished_at

    def publishable?
      attempted_this_run? && PUBLISHED_STATUSES.include?(summary["status"])
    end

    # A service this run attempted records the run's own start token as its
    # `last_attempted`; a skipped service replays the timestamp of its
    # previous attempt and must not publish a phantom run. Compared as
    # parsed instants so equivalent timestamp formats still match.
    def attempted_this_run?
      attempted = iso_timestamp(parse_time(summary["last_attempted"]))
      attempted.present? && attempted == iso_timestamp(parse_time(sync_started_at))
    end

    def enqueue_context
      {
        service_type:,
        service_instance:,
        sync_run_id:,
        observed_at: finished_at
      }
    end

    def payload
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        sync_run_id:,
        service_type:,
        service_instance:,
        started_at: iso_timestamp(parse_time(sync_started_at)),
        finished_at: iso_timestamp(finished_at),
        last_attempted_at: iso_timestamp(parse_time(summary["last_attempted"])),
        last_successful_at: iso_timestamp(parse_time(summary["last_successful"])),
        last_failed_at: iso_timestamp(parse_time(summary["last_failed"])),
        status: summary["status"],
        items_synced: summary["items_synced"].to_i,
        touched_collection_ids:,
        detail: summary["detail"],
        error: error_payload
      }
    end

    # Matches the run scope ObservationEmitter records in observation
    # provenance so TaskBridge Web can correlate one run's rows.
    def sync_run_id
      "sync-run-#{sync_started_at}"
    end

    # Same identity convention as Outbox::SourceIdentity (identifier of the
    # service class, instance-qualified only in service_instance) so
    # sync-run rows group with the item rows of the service they summarize.
    def service_type
      Base::Service.service_identifier_for(Base::Service.class_name_for(service_name))
    end

    def service_instance
      [service_type, Base::Service.instance_name_for(service_name)].compact.join(":")
    end

    def service_name
      summary.fetch("service")
    end

    def touched_collection_ids
      logs.flat_map { |entry| Array(entry["touched_collection_ids"] || entry[:touched_collection_ids]) }.compact.uniq
    end

    # Run-level outcomes are never retried in-process: the next scheduled
    # sync starts a fresh run with its own summary row, so `retryable`
    # reflects the run policy TaskBridge actually used (RDR #215).
    def error_payload
      return unless summary["status"] == "failed"

      failed_entry = logs.reverse.find { |entry| entry["error_class"].present? || entry["error_message"].present? }
      return unless failed_entry

      {
        class: failed_entry["error_class"],
        message: failed_entry["error_message"],
        retryable: false
      }.compact
    end

    def parse_time(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return if value.blank?

      Time.zone.parse(value.to_s)
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
