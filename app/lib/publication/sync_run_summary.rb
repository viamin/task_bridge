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
    REQUIRED_ERROR_KEYS = %i[class message retryable].freeze

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

      validate!
    end

    def to_payload
      {
        contract_version: CONTRACT_VERSION,
        idempotency_key:,
        sync_run_id:,
        service_type:,
        service_instance:,
        started_at: Timestamp.format(started_at),
        finished_at: Timestamp.format(finished_at),
        last_attempted_at: Timestamp.format(last_attempted_at),
        last_successful_at: Timestamp.format(last_successful_at),
        last_failed_at: Timestamp.format(last_failed_at),
        status:,
        items_synced:,
        touched_collection_ids: touched_collection_ids || [],
        detail: sanitized_detail,
        error: sanitized_error
      }.compact
    end

    private

    def sanitized_detail
      OperationalText.sanitize(detail)
    end

    def sanitized_error
      return if error.nil?
      return sanitize_error_value(error) unless HashAccess.key?(error, :message)

      message_key = error.key?(:message) ? :message : "message"
      sanitized_error = sanitize_error_value(error.except(:message, "message"))
      sanitized_error[message_key] = OperationalText.sanitize(HashAccess.fetch(error, :message))
      sanitized_error
    end

    def sanitize_error_value(value)
      case value
      when String
        OperationalText.sanitize(value)
      when Array
        value.map { |item| sanitize_error_value(item) }
      when Hash
        value.each_with_object({}) do |(key, nested), sanitized|
          sanitized[key] = sanitize_error_value(nested)
        end
      else
        value
      end
    end

    def validate!
      validate_text_encoding!
      raise ArgumentError, "idempotency_key is required" if idempotency_key.blank?
      raise ArgumentError, "idempotency_key must be a string" unless idempotency_key.is_a?(String)
      raise ArgumentError, "sync_run_id is required" if sync_run_id.blank?
      raise ArgumentError, "sync_run_id must be a string" unless sync_run_id.is_a?(String)
      raise ArgumentError, "service_type is required" if service_type.blank?
      raise ArgumentError, "service_type must be a string" unless service_type.is_a?(String)
      raise ArgumentError, "service_instance is required" if service_instance.blank?
      raise ArgumentError, "service_instance must be a string" unless service_instance.is_a?(String)
      raise ArgumentError, "started_at is required" if started_at.blank?
      raise ArgumentError, "finished_at is required" if finished_at.blank?
      raise ArgumentError, "last_attempted_at is required" if last_attempted_at.blank?
      raise ArgumentError, "status must be one of: #{VALID_STATUSES.join(', ')}" unless VALID_STATUSES.include?(status)
      raise ArgumentError, "items_synced must be a non-negative integer" unless items_synced.is_a?(Integer) && items_synced >= 0
      raise ArgumentError, "detail must be a string when provided" unless detail.nil? || detail.is_a?(String)

      validate_touched_collection_ids!
      validate_error!(error)
      validate_completion_timestamps!
      validate_error_status!
      Timestamp.validate!(started_at, finished_at, last_attempted_at, last_successful_at, last_failed_at)
      validate_timestamp_order!
    end

    # touched_collection_ids reference TaskBridge sync_collection integer IDs;
    # a wrong-typed entry would surface as a remote non-retryable row
    # rejection, so it is rejected at this boundary instead.
    def validate_touched_collection_ids!
      ids = touched_collection_ids
      return if ids.nil? || valid_touched_collection_ids?(ids)

      raise ArgumentError, "touched_collection_ids must be an array of unique non-negative integers when provided"
    end

    def valid_touched_collection_ids?(ids)
      ids.is_a?(Array) && ids.all? { |id| id.is_a?(Integer) && id >= 0 } && ids.uniq == ids
    end

    # error carries the run's retry classification; a row without it cannot be
    # acted on downstream, so its shape is enforced when the field is present.
    # retryable must be a real boolean because callers branch on it directly.
    def validate_error!(error)
      return if error.nil?
      return if valid_error?(error)

      raise ArgumentError, "error must be a hash with #{REQUIRED_ERROR_KEYS.join(', ')} (class and message as non-blank strings, retryable boolean) when provided"
    end

    def valid_error?(error)
      error.is_a?(Hash) &&
        REQUIRED_ERROR_KEYS.all? { |key| HashAccess.key?(error, key) } &&
        HashAccess.fetch(error, :class).is_a?(String) && HashAccess.fetch(error, :class).present? &&
        HashAccess.fetch(error, :message).is_a?(String) && HashAccess.fetch(error, :message).present? &&
        [true, false].include?(HashAccess.fetch(error, :retryable))
    end

    # RDR 215 lists last_successful_at or last_failed_at as required "as
    # applicable": the summary must carry the completion timestamp matching
    # its outcome so TaskBridge Web can correlate operational health, and a
    # terminal outcome must not also claim the opposite terminal timestamp.
    def validate_completion_timestamps!
      case status
      when "success"
        raise ArgumentError, "last_successful_at is required for a success run" if last_successful_at.blank?
        raise ArgumentError, "last_failed_at is not valid for a success run" unless last_failed_at.nil?
      when "failed"
        raise ArgumentError, "last_failed_at is required for a failed run" if last_failed_at.blank?
        raise ArgumentError, "last_successful_at is not valid for a failed run" unless last_successful_at.nil?
      else
        return unless last_successful_at.blank? && last_failed_at.blank?

        raise ArgumentError, "last_successful_at or last_failed_at is required for a partial run"
      end
    end

    # A successful run may still carry operational detail, but publishing an
    # error object alongside status: success is contradictory contract data.
    # Partial and failed runs may include error details when they ended with a
    # real failure condition.
    def validate_error_status!
      return unless status == "success" && error.present?

      raise ArgumentError, "error is not valid for a success run"
    end

    # A sync-run summary describes one bounded run. Accepting timestamps that
    # fall outside that window would publish impossible operational facts that
    # TaskBridge Web cannot interpret sensibly.
    def validate_timestamp_order!
      started = parse_timestamp(started_at)
      finished = parse_timestamp(finished_at)
      attempted = parse_timestamp(last_attempted_at)

      raise ArgumentError, "finished_at must be at or after started_at" if finished < started
      raise ArgumentError, "last_attempted_at must be between started_at and finished_at" unless within_run_window?(attempted, started, finished)

      validate_completion_timestamp_order!(last_successful_at, field: :last_successful_at, started:, finished:)
      validate_completion_timestamp_order!(last_failed_at, field: :last_failed_at, started:, finished:)
    end

    def validate_completion_timestamp_order!(value, field:, started:, finished:)
      return if value.nil?

      timestamp = parse_timestamp(value)
      return if within_run_window?(timestamp, started, finished)

      raise ArgumentError, "#{field} must be between started_at and finished_at"
    end

    def within_run_window?(timestamp, started_at, finished_at)
      timestamp.between?(started_at, finished_at)
    end

    def parse_timestamp(value)
      value.is_a?(Time) ? value : Timestamp.parse_string(value)
    end

    # detail and error text are operational free text; malformed UTF-8 bytes
    # must fail at this boundary instead of crashing JSON generation deep in
    # the publisher. Runs before the other checks because present?/blank?
    # themselves raise on invalid byte sequences. Non-string values are left
    # to the type checks that follow.
    def validate_text_encoding!
      fields = { idempotency_key:, sync_run_id:, service_type:, service_instance:, "detail" => detail,
                 started_at:, finished_at:, last_attempted_at:, last_successful_at:, last_failed_at: }
      Utf8.validate_fields!(fields)
      Utf8.validate_structure!(:error, error) if error.is_a?(Hash)
    end
  end
end
