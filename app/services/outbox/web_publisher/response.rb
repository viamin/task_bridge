# frozen_string_literal: true

module Outbox
  class WebPublisher
    # The reduced outcome of one batch POST, safe to log: it carries
    # status codes and short server-provided messages, never the API
    # key, request headers, or row payloads.
    class Response
      ROW_RESULTS = :row_results
      RETRYABLE = :retryable
      TERMINAL = :terminal

      HTTP_OK = 200
      PAYLOAD_TOO_LARGE = 413
      RETRYABLE_STATUSES = [PAYLOAD_TOO_LARGE, 429].freeze
      MESSAGE_LIMIT = 300

      attr_reader :status, :error_class, :error_message

      def self.from_http(status, body)
        new(status:, body:, error_class: nil, error_message: nil)
      end

      def self.failure(error_class, error_message)
        new(status: nil, body: nil, error_class:, error_message:)
      end

      def initialize(status:, body:, error_class:, error_message:)
        @status = status
        @parsed_body = parse(body)
        @error_class = error_class
        @error_message = error_message
      end

      def outcome
        return RETRYABLE if @error_class
        return ROW_RESULTS if row_results
        # A 200 that cannot be reconciled (missing/unparseable `results`)
        # leaves every row undelivered: retrying is safe because rows are
        # idempotent, so treat it like any other transient failure.
        return RETRYABLE if retryable_status? || status == HTTP_OK

        TERMINAL
      end

      # The per-row result entries for a 200 OK, or nil when the response
      # cannot be reconciled (unparseable body, missing `results`): every
      # submitted row must then be treated as not delivered.
      def row_results
        return nil unless status == HTTP_OK
        return nil unless @parsed_body.is_a?(Hash)

        results = @parsed_body["results"]
        results.is_a?(Array) ? results : nil
      end

      def error_code
        return @error_class if @error_class
        return "http_#{status}" if status

        "unknown"
      end

      # A 413 rejects the batch size, not its rows (RDR #215): the rows
      # stay valid and should be re-sent in a smaller batch.
      def payload_too_large?
        status == PAYLOAD_TOO_LARGE
      end

      def summary_message
        return truncate(@error_message) if @error_class

        truncate(server_message || "HTTP #{status}")
      end

      private

      def retryable_status?
        RETRYABLE_STATUSES.include?(status) || (500..599).cover?(status)
      end

      def server_message
        return unless @parsed_body.is_a?(Hash)

        error = @parsed_body["error"]
        return error["message"] if error.is_a?(Hash)
        return error if error.is_a?(String)

        @parsed_body["message"]
      end

      def parse(body)
        JSON.parse(body.to_s)
      rescue JSON::ParserError, TypeError
        nil
      end

      def truncate(message)
        message.to_s.truncate(MESSAGE_LIMIT)
      end
    end
  end
end
