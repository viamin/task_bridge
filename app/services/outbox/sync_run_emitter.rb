# frozen_string_literal: true

module Outbox
  # Emits `sync_run` summary rows (RDR #215 "Sync-Run Summary Schema") into
  # the local outbox so TaskBridge Web can correlate item observations with
  # operational health. One row per service run: skipped and idle services
  # publish nothing, matching the run states StructuredLogger already
  # records. Like every emitter this is bookkeeping around sync — the write
  # is isolated via Outbox::IsolatedWrite and never changes the run result
  # it summarizes.
  class SyncRunEmitter
    PUBLISHED_STATUSES = %w[success failed].freeze
    DETAIL_LIMIT = 300

    def self.emit_for_service(service_name, summary:, logs:, finished_at:)
      new(service_name, summary:, logs:, finished_at:).emit
    end

    def initialize(service_name, summary:, logs:, finished_at:)
      @service_name = service_name
      @summary = summary.stringify_keys
      @logs = Array(logs).map(&:stringify_keys)
      @finished_at = finished_at
    end

    def emit
      return unless publishable?

      Outbox::IsolatedWrite.call("sync run for #{sync_run_id}") do
        OutboxEntry.enqueue(record_kind: :sync_run, payload:, **enqueue_context)
      end
    end

    private

    attr_reader :service_name, :summary, :logs, :finished_at

    def publishable?
      PUBLISHED_STATUSES.include?(summary["status"])
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
        started_at: iso_timestamp(started_at),
        finished_at: iso_timestamp(finished_at),
        last_attempted_at: iso_timestamp(started_at),
        last_successful_at: iso_timestamp(summary["last_successful"]),
        last_failed_at: iso_timestamp(summary["last_failed"]),
        status: summary["status"],
        items_synced: summary.fetch("items_synced", 0).to_i,
        touched_collection_ids: touched_collection_ids,
        detail: detail,
        error: error
      }
    end

    # RDR #215 run scope, e.g. "sync-run-20260814T192000Z-asana", mirroring
    # Disappearance::Detector so observations and their enclosing run agree.
    def sync_run_id
      @sync_run_id ||= "sync-run-#{started_at.utc.strftime('%Y%m%dT%H%M%SZ')}-#{service_type}"
    end

    # Same shape as Outbox::SourceIdentity: the adapter family plus the
    # configured instance qualifier, so two configured accounts of one
    # provider publish distinct run scopes.
    def service_type
      @service_type ||= Base::Service.service_identifier_for(
        Base::Service.class_name_for(service_name)
      )
    end

    def service_instance
      [service_type, Base::Service.instance_name_for(service_name)].compact.join(":")
    end

    # The run's identity: every service log carries the run-scoped
    # last_attempted timestamp (options[:sync_started_at]).
    def started_at
      @started_at ||= timestamp(summary["last_attempted"]) || Time.current
    end

    def touched_collection_ids
      logs.flat_map { |entry| Array(entry["touched_collection_ids"]) }.compact.uniq
    end

    def detail
      summary["detail"].to_s.truncate(DETAIL_LIMIT).presence
    end

    # TaskBridge retries every failed service on the next scheduled sync
    # run and keeps no terminal run classification, so `retryable: true`
    # states the retry policy actually used (RDR #215 error rules).
    def error
      return unless summary["status"] == "failed"

      failed_entry = logs.reverse.find do |entry|
        entry["status"].to_s == "failed" || entry["error_message"].present?
      end
      {
        class: failed_entry&.[]("error_class").presence || "ProviderError",
        message: failed_entry&.[]("error_message").to_s.truncate(DETAIL_LIMIT).presence,
        retryable: true
      }
    end

    def timestamp(value)
      return value if value.is_a?(ActiveSupport::TimeWithZone) || value.is_a?(Time)
      return if value.to_s.blank?

      Time.zone.parse(value.to_s)
    end

    def iso_timestamp(value)
      timestamp(value)&.utc&.iso8601(6)
    end
  end
end
