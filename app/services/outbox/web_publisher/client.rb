# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module Outbox
  class WebPublisher
    # Posts batches to TaskBridge Web and reduces every outcome — HTTP
    # status or network failure — to one of three publisher actions
    # (RDR #215 HTTP status guidance):
    #
    #   :row_results — 200 OK; reconcile each row from `results`
    #   :retryable   — 413/429/5xx or a network error; retry with backoff
    #   :terminal    — 400/401/409/422 or an unexpected status; operator
    #                  review, resend a corrected batch
    class Client
      Raw = Struct.new(:status, :body)

      def initialize(config, transport: nil)
        @config = config
        @transport = transport || HttpTransport.new(config)
      end

      def post_batch(batch)
        raw = transport.post(
          batch.body_json,
          headers: batch.headers(api_key: config.api_key),
          timeout: config.timeout_seconds
        )
        Response.from_http(raw.status, raw.body)
      rescue *HttpTransport::RETRYABLE_ERRORS => e
        Response.failure(e.class.name, e.message)
      end

      private

      attr_reader :config, :transport

      # Net::HTTP transport for the ingestion endpoint. The base URL comes
      # from trusted deployment configuration (never from payload data).
      class HttpTransport
        # Net::HTTP's transient transport failures plus connect-time
        # errors. SystemCallError is the parent of every Errno::*
        # (ECONNRESET, ENETDOWN, EHOSTDOWN, EADDRNOTAVAIL, ...), so each
        # network-level errno — including ones Net::HTTP would retry for
        # idempotent verbs but re-raises for a POST — is reduced to a
        # retryable response instead of escaping post_batch.
        RETRYABLE_ERRORS = [
          EOFError,
          SystemCallError,
          IOError,
          Net::HTTPBadResponse,
          Net::OpenTimeout,
          Net::ReadTimeout,
          Net::WriteTimeout,
          OpenSSL::SSL::SSLError,
          SocketError
        ].freeze

        def initialize(config)
          @uri = config.uri
        end

        def post(body, headers:, timeout:)
          http = Net::HTTP.new(@uri.host, @uri.port)
          http.use_ssl = @uri.scheme == "https"
          http.open_timeout = timeout
          http.read_timeout = timeout
          http.write_timeout = timeout if http.respond_to?(:write_timeout=)
          request = Net::HTTP::Post.new(full_path, headers)
          request.body = body
          response = http.request(request)
          Raw.new(response.code.to_i, response.body)
        end

        private

        # Preserve any path prefix in the configured base URL.
        def full_path
          [@uri.path.chomp("/"), Batch::ENDPOINT_PATH].join
        end
      end
    end
  end
end
