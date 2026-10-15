# frozen_string_literal: true

module Outbox
  # Emits one `sync_run` summary row (RDR #215) into the local outbox per
  # service run so TaskBridge Web can correlate item observations with
  # operational health. Run summaries are bookkeeping around sync (#221):
  # enqueue failures are isolated via Outbox::IsolatedWrite and never
  # change the run's outcome or exit status.
  #
  # The `sync_run_id` is `sync-run-<started_at compacted>-<service_identifier>`,
  # derived from the run's deterministic `sync_started_at`. Nonzero
  # microseconds are retained so consecutive runs of the same service cannot
  # collapse into one idempotency key. Sharing this
  # derivation with Outbox::ObservationEmitter and Disappearance::Detector
  # keeps `provenance.sync_run_id` joinable across record kinds for the
  # same run.
  class SyncRunEmitter
    PUBLISHED_STATUSES = %w[success failed].freeze

    def self.emit_for_run(service_name:, summary:, logs:, options:)
      Outbox::IsolatedWrite.call("sync_run for #{service_name}") do
        new(service_name:, summary:, logs:, options:).emit
      end
    end

    # The deterministic, run-scoped identifier shared by every fact in one
    # service run (RDR #215): sync-run summaries, item observations, and
    # deletion tombstones. Returns nil when `sync_started_at` is missing or
    # invalid so callers can skip the field without interrupting a sync.
    def self.run_id_for(service_name:, sync_started_at:)
      service_identity = Base::Service.parse_service_name(service_name)
      return if service_identity[:class_name].blank?

      started_at = parse_started_at(sync_started_at)
      return nil unless started_at

      compacted = compact_timestamp(started_at)
      identifier = Base::Service.service_identifier_for(service_identity[:service_name])
      "sync-run-#{compacted}-#{identifier}"
    end

    def self.parse_started_at(value)
      return if value.blank?
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return if value.is_a?(String) && Date._iso8601(value).fetch(:offset, nil).nil?

      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def self.compact_timestamp(time)
      seconds = time.utc.strftime("%Y%m%dT%H%M%S")
      return "#{seconds}Z" if time.usec.zero?

      "#{seconds}.#{format('%06d', time.usec)}Z"
    end
    private_class_method :compact_timestamp

    def initialize(service_name:, summary:, logs:, options:)
      @service_name = service_name
      @summary = summary.is_a?(Hash) ? summary : {}
      @logs = Array(logs).grep(Hash)
      @options = options.is_a?(Hash) ? options : {}
    end

    def emit
      return nil unless eligible?

      OutboxEntry.enqueue(
        record_kind: :sync_run,
        payload: payload,
        **enqueue_context
      )
    end

    private

    attr_reader :service_name, :summary, :logs, :options

    def eligible?
      return false if pretend?
      return false if sync_run_id.blank?
      return false unless PUBLISHED_STATUSES.include?(status)
      return false if last_attempted_at.nil?

      true
    end

    def payload
      base.merge(
        "started_at" => started_at,
        "finished_at" => finished_at,
        "last_attempted_at" => last_attempted_at,
        "last_successful_at" => timestamp("last_successful"),
        "last_failed_at" => timestamp("last_failed"),
        "status" => status,
        "items_synced" => items_synced,
        "touched_collection_ids" => touched_collection_ids,
        "detail" => bound_detail,
        "error" => error_payload
      )
    end

    def base
      {
        "contract_version" => OutboxEntry::PAYLOAD_VERSION,
        "sync_run_id" => sync_run_id,
        "service_type" => service_type,
        "service_instance" => service_instance
      }
    end

    def enqueue_context
      {
        service_type:,
        service_instance:,
        sync_run_id:,
        observed_at: finished_at_time
      }
    end

    def sync_run_id
      @sync_run_id ||= self.class.run_id_for(
        service_name:,
        sync_started_at:
      )
    end

    def sync_started_at
      options[:sync_started_at] || options["sync_started_at"]
    end

    def pretend?
      options[:pretend] == true || options["pretend"] == true
    end

    def started_at
      started_at_time.utc.iso8601(6)
    end

    def started_at_time
      @started_at_time ||= self.class.parse_started_at(sync_started_at)
    end

    def finished_at
      finished_at_time.utc.iso8601(6)
    end

    def finished_at_time
      @finished_at_time ||= Time.current
    end

    def status
      (summary[:status] || summary["status"]).to_s
    end

    def items_synced
      count = Integer(summary_value("items_synced"), exception: false)
      count&.positive? ? count : 0
    end

    def timestamp(key)
      raw = summary_value(key)
      return nil if raw.blank?

      self.class.parse_started_at(raw)&.utc&.iso8601(6)
    end

    def last_attempted_at
      @last_attempted_at ||= timestamp("last_attempted") || started_at
    end

    def summary_value(key)
      summary[key] || summary[key.to_s] || summary[key.to_sym]
    end

    def touched_collection_ids
      logs.flat_map { |log| Array(log["touched_collection_ids"] || log[:touched_collection_ids]) }
          .select { |identifier| identifier.is_a?(Integer) && identifier.positive? }
          .uniq
          .sort
    end

    def bound_detail
      return "#{items_synced} items processed" if status == "success" && items_synced.positive?
      return "No changes detected" if status == "success"

      "Sync failed"
    end

    def error_payload
      return nil unless status == "failed"

      message = error_message
      {
        "class" => error_category,
        "message" => message,
        "retryable" => retryable?
      }
    end

    def error_category
      retryable? ? "ProviderError" : "ProviderAuthenticationError"
    end

    def error_message
      retryable? ? "The provider request failed" : "The provider rejected the request"
    end

    def failure_log
      @failure_log ||= logs.reverse.find do |log|
        log["status"].to_s == "failed" || log[:status].to_s == "failed" ||
          log["error_message"].present? || log[:error_message].present?
      end
    end

    # RDR #215: error.retryable must match the retry policy TaskBridge used
    # for the run outcome. Authentication-class failures are not retryable
    # (TaskBridge retries the run only on the next scheduled invocation, but
    # invalid credentials do not recover on their own), and most 4xx provider
    # failures share that classification. Rate limiting (429) is transient,
    # however, so it remains retryable. Other provider failures stay retryable
    # per the existing scheduled-run policy. The error class
    # alone rarely carries the HTTP status, so we also inspect the
    # operational error message.
    def retryable?
      combined = "#{failure_error_class} #{error_message_for_retry_check}"
      return false if combined.match?(/Authentication|Authorization|Unauthorized|InvalidToken|InvalidCredentials|Forbidden|BadRequest|NotFound/i)
      return false if combined.match?(/\b4(?!29\b)\d{2}\b/)

      true
    end

    def error_message_for_retry_check
      summary[:error_message] || summary["error_message"] || failure_log_value("error_message").to_s
    end

    def failure_error_class
      summary[:error_class] || summary["error_class"] || failure_log_value("error_class").to_s
    end

    def failure_log_value(key)
      return unless failure_log

      failure_log[key] || failure_log[key.to_sym]
    end

    def service_identity
      @service_identity ||= Base::Service.parse_service_name(service_name)
    end

    def service_type
      service_identity[:class_name].to_s.underscore
    end

    def service_instance
      instance = service_identity[:instance_name].presence
      instance ? "#{service_type}:#{instance}" : service_type
    end
  end
end
