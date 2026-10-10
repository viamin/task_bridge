# frozen_string_literal: true

module Outbox
  # Publishes one sync-run summary row per service run (RDR #215 "Sync-Run
  # Summary Schema") so TaskBridge Web can correlate item observations with
  # operational health. Only `success` and `failed` runs publish: skipped or
  # idle services must not (RDR). Emission is bookkeeping after the run's
  # outcome is already known — an enqueue failure is isolated and reported
  # through Outbox::IsolatedWrite and never changes the run result.
  class SyncRunEmitter
    PUBLISHABLE_STATUSES = %w[success failed].freeze
    # TaskBridge's retry policy for failed service runs is to re-attempt on
    # the next scheduled sync, so every failed run is retryable (RDR #215:
    # error.retryable must match the policy used for the outcome).
    RETRYABLE = true

    def self.emit_for(service_name:, summary:, service_logs:, started_at:, finished_at:)
      new(service_name:, summary:, service_logs:, started_at:, finished_at:).emit
    end

    def initialize(service_name:, summary:, service_logs:, started_at:, finished_at:)
      @service_name = service_name
      @summary = summary.stringify_keys
      @service_logs = Array(service_logs)
      # The sync task passes the ISO 8601 string it stores in
      # options[:sync_started_at]; normalize it once so every derived value
      # (id, started_at) matches the observation provenance exactly.
      @started_at = started_at.respond_to?(:utc) ? started_at : Time.iso8601(started_at.to_s)
      @finished_at = finished_at
    end

    def emit
      return unless publishable?

      Outbox::IsolatedWrite.call("sync run summary for #{service_name}") do
        OutboxEntry.enqueue(record_kind: :sync_run, payload:, **enqueue_context)
      end
    end

    private

    attr_reader :service_name, :summary, :service_logs, :started_at, :finished_at

    def publishable?
      PUBLISHABLE_STATUSES.include?(summary["status"])
    end

    def payload
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        sync_run_id:,
        service_type: service_identity[:service_type],
        service_instance: service_identity[:service_instance],
        started_at: iso_timestamp(started_at),
        finished_at: iso_timestamp(finished_at),
        last_attempted_at: summary["last_attempted"],
        last_successful_at: summary["last_successful"],
        last_failed_at: summary["last_failed"],
        status: summary["status"],
        items_synced: summary.fetch("items_synced", 0).to_i,
        touched_collection_ids: touched_collection_ids,
        detail: summary["detail"],
        error: error_payload
      }
    end

    def enqueue_context
      {
        service_type: service_identity[:service_type],
        service_instance: service_identity[:service_instance],
        sync_run_id:,
        observed_at: finished_at
      }
    end

    # The identity spine shared with item-scoped rows (Outbox::SourceIdentity):
    # the adapter family identifier plus the configured instance name, e.g.
    # "asana:work" for the Asana:work service.
    def service_identity
      parsed_service = Base::Service.parse_service_name(service_name)
      service_type = Base::Service.service_identifier_for(parsed_service[:class_name])
      {
        service_type:,
        service_instance: [service_type, parsed_service[:instance_name]].compact.join(":")
      }
    end

    def sync_run_id
      Outbox::SyncRunId.for(service_name, at: started_at)
    end

    def touched_collection_ids
      service_logs.flat_map { |log| Array(log["touched_collection_ids"] || log[:touched_collection_ids]) }.compact.uniq
    end

    # The failing entry the run's summary was built from, if any. `detail`
    # and `error.message` carry only the sanitized operational text already
    # recorded by StructuredLogger / sync_result (RDR #215).
    def error_payload
      failure = service_logs.reverse.find { |log| log["error_message"].present? }
      return nil if failure.blank?

      {
        class: failure["error_class"].presence || "ProviderError",
        message: failure["error_message"],
        retryable: RETRYABLE
      }
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
