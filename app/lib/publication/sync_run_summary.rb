# frozen_string_literal: true

module Publication
  # Represents a sync-run operational summary for one service run.
  #
  # One summary should be published per service run so TaskBridge Web can correlate
  # item observations with operational health. Skipped or idle services should not
  # publish a sync-run summary.
  #
  # Required fields: idempotency_key, sync_run_id, service_type, service_instance,
  # started_at, finished_at, last_attempted_at, status, items_synced.
  class SyncRunSummary
    VALID_STATUSES = %w[success failed partial].freeze
    RECORD_KIND = "sync_run"

    TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%S.%6NZ"

    attr_reader :idempotency_key, :sync_run_id, :service_type, :service_instance,
                :started_at, :finished_at, :last_attempted_at, :status, :items_synced,
                :last_successful_at, :last_failed_at, :touched_collection_ids, :detail, :error

    def initialize(
      idempotency_key:,
      sync_run_id:,
      service_type:,
      service_instance:,
      started_at:,
      finished_at:,
      last_attempted_at:,
      status:,
      items_synced:,
      last_successful_at: nil,
      last_failed_at: nil,
      touched_collection_ids: nil,
      detail: nil,
      error: nil
    )
      validate!(idempotency_key:, sync_run_id:, service_type:, service_instance:,
                started_at:, finished_at:, last_attempted_at:, status:, items_synced:)

      @idempotency_key = idempotency_key
      @sync_run_id = sync_run_id
      @service_type = service_type
      @service_instance = service_instance
      @started_at = started_at
      @finished_at = finished_at
      @last_attempted_at = last_attempted_at
      @status = status
      @items_synced = items_synced
      @last_successful_at = last_successful_at
      @last_failed_at = last_failed_at
      @touched_collection_ids = touched_collection_ids
      @detail = detail
      @error = error
    end

    def to_payload
      {
        contract_version: 1,
        idempotency_key:,
        sync_run_id:,
        service_type:,
        service_instance:,
        started_at: format_timestamp(started_at),
        finished_at: format_timestamp(finished_at),
        last_attempted_at: format_timestamp(last_attempted_at),
        last_successful_at: format_timestamp(last_successful_at),
        last_failed_at: format_timestamp(last_failed_at),
        status:,
        items_synced:,
        touched_collection_ids: touched_collection_ids || [],
        detail:,
        error:
      }.compact
    end

    private

    def validate!(idempotency_key:, sync_run_id:, service_type:, service_instance:,
                  started_at:, finished_at:, last_attempted_at:, status:, items_synced:)
      raise ArgumentError, "idempotency_key is required" if idempotency_key.blank?
      raise ArgumentError, "sync_run_id is required" if sync_run_id.blank?
      raise ArgumentError, "service_type is required" if service_type.blank?
      raise ArgumentError, "service_instance is required" if service_instance.blank?
      raise ArgumentError, "started_at is required" if started_at.nil?
      raise ArgumentError, "finished_at is required" if finished_at.nil?
      raise ArgumentError, "last_attempted_at is required" if last_attempted_at.nil?
      raise ArgumentError, "status must be one of: #{VALID_STATUSES.join(', ')}" unless VALID_STATUSES.include?(status)
      raise ArgumentError, "items_synced is required" if items_synced.nil?
    end

    def format_timestamp(value)
      return nil if value.nil?
      return value if value.is_a?(String)

      value.utc.strftime(TIMESTAMP_FORMAT)
    end
  end
end
