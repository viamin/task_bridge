# frozen_string_literal: true

module Outbox
  # Emits one `sync_run` summary row per service run (RDR #215 Sync-Run
  # Summary Schema, issue #221) so TaskBridge Web can correlate item
  # observations with operational health. Only success and failed runs
  # publish; skipped or idle services publish nothing (RDR #215).
  # Emission is bookkeeping around sync — wrapped in Outbox::IsolatedWrite
  # so an outbox write failure never changes the run's own result — and
  # `--pretend` runs enqueue nothing (enforced inside OutboxEntry.enqueue).
  class SyncRunEmitter
    PUBLISHABLE_STATUSES = %w[success failed].freeze

    def self.emit_for(service_name:, summary:, started_at:, logs: [])
      Outbox::IsolatedWrite.call("sync run for #{service_name}") do
        new(service_name, summary, started_at, logs).emit
      end
    end

    def initialize(service_name, summary, started_at, logs)
      @service_name = service_name
      @summary = summary.stringify_keys
      @started_at = started_at
      @logs = Array(logs).compact
    end

    def emit
      return unless publishable?

      OutboxEntry.enqueue(record_kind: :sync_run, payload:, **enqueue_context)
    end

    private

    attr_reader :service_name, :summary, :started_at, :logs

    def publishable?
      PUBLISHABLE_STATUSES.include?(summary["status"]) && started_at.present?
    end

    def enqueue_context
      {
        service_type: service_type,
        service_instance: service_instance,
        sync_run_id: sync_run_id,
        observed_at: finished_at,
        idempotency_key: Outbox::IdempotencyKey.for(
          record_kind: :sync_run, observed_at: finished_at,
          service_instance:, sync_run_id:
        )
      }
    end

    def payload
      {
        "contract_version" => OutboxEntry::PAYLOAD_VERSION,
        "sync_run_id" => sync_run_id,
        "service_type" => service_type,
        "service_instance" => service_instance,
        "started_at" => iso_timestamp(started_at),
        "finished_at" => iso_timestamp(finished_at),
        "last_attempted_at" => iso_timestamp(summary["last_attempted"]) || iso_timestamp(started_at),
        "last_successful_at" => iso_timestamp(summary["last_successful"]),
        "last_failed_at" => iso_timestamp(summary["last_failed"]),
        "status" => summary["status"],
        "items_synced" => summary.fetch("items_synced", 0).to_i,
        "touched_collection_ids" => touched_collection_ids,
        "detail" => summary["detail"].presence,
        "error" => error_payload
      }.compact
    end

    # TaskBridge does not retry a failed run; the next scheduled run is a
    # new sync_run_id. RDR #215: `error.retryable` must match that policy.
    def error_payload
      return unless summary["status"] == "failed"

      failed_entry = logs.reverse.find { |entry| entry["error_class"].present? || entry["error_message"].present? }
      return unless failed_entry

      {
        "class" => failed_entry["error_class"].presence || "ProviderError",
        "message" => failed_entry["error_message"].to_s.presence,
        "retryable" => false
      }
    end

    def touched_collection_ids
      logs.flat_map { |entry| Array(entry["touched_collection_ids"] || entry[:touched_collection_ids]) }.compact.uniq
    end

    def sync_run_id
      @sync_run_id ||= Outbox::SyncRunId.for(service_name, at: started_at)
    end

    def service_type
      @service_type ||= Base::Service.service_identifier_for(Base::Service.class_name_for(service_name))
    end

    # Mirrors Outbox::SourceIdentity: "<service_type>[:<instance_name>]".
    def service_instance
      @service_instance ||= [service_type, Base::Service.instance_name_for(service_name)].compact.join(":")
    end

    def finished_at
      @finished_at ||= Time.current
    end

    def iso_timestamp(value)
      return if value.blank?

      parsed = value.is_a?(String) ? Time.zone.parse(value) : value
      parsed&.utc&.iso8601(6)
    end
  end
end
