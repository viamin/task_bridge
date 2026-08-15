# frozen_string_literal: true

module Publication
  # Publishes a batch of outbox entries to TaskBridge Web via HTTP.
  #
  # The publisher is stateless. The caller is responsible for selecting the entries
  # to include in the batch and for acting on the returned result.
  #
  # Usage:
  #   entries = PublicationOutboxEntry.publishable.limit(100)
  #   result  = Publication::BatchPublisher.new(endpoint:, api_key:).publish(entries)
  #   result.each do |entry_result|
  #     entry_result.entry.mark_delivered! if entry_result.accepted?
  #   end
  class BatchPublisher
    CONTRACT_VERSION = 1
    DEFAULT_TIMEOUT  = 30 # seconds
    # Canonical record kinds the batch body can carry, mirroring the contract arrays.
    RECORD_KINDS = PublicationOutboxEntry::RECORD_KINDS.freeze
    # Per-row statuses defined by the contract response format.
    VALID_RESULT_STATUSES = %w[accepted replayed rejected].freeze

    EntryResult = Struct.new(:entry, :status, :retryable, :error_code, :message, keyword_init: true) do
      def accepted?  = status == "accepted"
      def replayed?  = status == "replayed"
      def rejected?  = status == "rejected"
    end

    attr_reader :endpoint, :api_key, :publisher_instance, :timeout

    def initialize(endpoint:, api_key:, publisher_instance: nil, timeout: DEFAULT_TIMEOUT)
      raise ArgumentError, "endpoint is required" if endpoint.blank?
      raise ArgumentError, "api_key is required" if api_key.blank?
      raise ArgumentError, "timeout must be a positive integer" unless timeout.is_a?(Integer) && timeout.positive?

      @endpoint           = endpoint
      @api_key            = api_key
      @publisher_instance = publisher_instance
      @timeout            = timeout
    end

    # Publishes outbox entries as a single HTTP batch.
    #
    # Returns an array of EntryResult, one per submitted entry, in submission order.
    # Raises Publication::DeliveryError on unrecoverable transport failures.
    def publish(entries)
      rows = Array(entries)
      raise ArgumentError, "entries must not be empty" if rows.empty?

      unknown = rows.map(&:record_kind).uniq - RECORD_KINDS
      raise ArgumentError, "unknown record_kind(s): #{unknown.join(', ')}" if unknown.any?

      check_duplicate_idempotency_keys!(rows)
      check_payload_contract_versions!(rows)

      batch_id     = SecureRandom.uuid
      sent_at      = Timestamp.format(Time.current)
      published_at = Timestamp.format(Time.current)
      body         = build_body(rows, batch_id:, sent_at:, published_at:)
      headers      = build_headers(batch_id:, sent_at:)

      response = post_batch(body:, headers:)
      handle_response(response, rows, batch_id:)
    end

    private

    # The contract forbids repeating an idempotency_key within a batch. The
    # outbox unique index normally prevents this, but the publisher guards any
    # caller-supplied entry collection.
    def check_duplicate_idempotency_keys!(rows)
      duplicates = rows.map(&:idempotency_key).tally.select { |_, count| count > 1 }.keys
      return if duplicates.empty?

      raise ArgumentError, "duplicate idempotency_key(s) in batch: #{duplicates.join(', ')}"
    end

    # The contract requires every row's contract_version to equal the batch's,
    # so a row persisted under a different major version must never be silently
    # sent through a v1 batch. Corrupt payloads fail here with a clear error
    # naming the offending row instead of a raw JSON or type error later.
    def check_payload_contract_versions!(rows)
      mismatched = rows.reject { |row| payload_contract_version(row) == CONTRACT_VERSION }
      return if mismatched.empty?

      keys = mismatched.map(&:idempotency_key).join(", ")
      raise ArgumentError, "payload contract_version must be #{CONTRACT_VERSION} for idempotency_key(s): #{keys}"
    end

    def payload_contract_version(row)
      parsed = row.parsed_payload
      raise ArgumentError, "payload for #{row.idempotency_key} must be a JSON object" unless parsed.is_a?(Hash)

      parsed[:contract_version]
    rescue JSON::ParserError => e
      raise ArgumentError, "unparseable payload for #{row.idempotency_key}: #{e.message}"
    end

    def build_body(rows, batch_id:, sent_at:, published_at:)
      grouped = rows.group_by(&:record_kind)

      {
        contract_version: CONTRACT_VERSION,
        batch: { batch_id:, sent_at:, publisher: "task_bridge", publisher_instance: }.compact,
        items: serialize_group(grouped["item"], published_at:),
        observations: serialize_group(grouped["observation"], published_at:),
        mappings: serialize_group(grouped["mapping"], published_at:),
        sync_runs: serialize_group(grouped["sync_run"], published_at:)
      }.to_json
    end

    # published_at is record-level transport metadata; every row in one publish
    # attempt shares the same value so the batch describes a single attempt.
    def serialize_group(entries, published_at:)
      Array(entries).map { |e| e.parsed_payload.merge(published_at:) }
    end

    def build_headers(batch_id:, sent_at:)
      {
        "Authorization" => "Bearer #{api_key}",
        "Content-Type" => "application/json",
        "X-TaskBridge-Contract-Version" => CONTRACT_VERSION.to_s,
        "X-TaskBridge-Batch-Id" => batch_id,
        "X-TaskBridge-Sent-At" => sent_at
      }
    end

    def post_batch(body:, headers:)
      HTTParty.post(
        endpoint,
        body:,
        headers:,
        timeout:
      )
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError, EOFError,
           OpenSSL::SSL::SSLError,
           Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ETIMEDOUT => e
      raise DeliveryError.new("transport error: #{e.message}", retryable: true)
    end

    def handle_response(response, rows, batch_id:)
      case response.code
      when 200
        parse_row_results(response, rows, batch_id:)
      when 400, 422
        raise DeliveryError.new("request rejected (#{response.code}): #{response.body}", retryable: false)
      when 401
        raise DeliveryError.new("authentication failure (401): check API key", retryable: false)
      when 409
        raise DeliveryError.new("batch conflict (409): duplicate idempotency key payload mismatch", retryable: false)
      when 413
        raise DeliveryError.new("payload too large (413): reduce batch size", retryable: true)
      when 429
        raise DeliveryError.new("rate limited (429): back off and retry", retryable: true)
      else
        raise DeliveryError.new("unexpected response (#{response.code}): #{response.body}", retryable: response.code >= 500)
      end
    end

    def parse_row_results(response, rows, batch_id:)
      parsed = JSON.parse(response.body, symbolize_names: true)
      raise DeliveryError.new("unexpected response body: expected a JSON object", retryable: true) unless parsed.is_a?(Hash)

      verify_batch_echo!(parsed, batch_id)
      verify_contract_version!(parsed)

      results = extract_results(parsed)
      verify_result_counts!(parsed, results, rows)
      results_by_key = results.index_by { |r| r[:idempotency_key] }

      rows.map { |entry| build_entry_result(entry, results_by_key[entry.idempotency_key]) }
    rescue JSON::ParserError => e
      raise DeliveryError.new("unparseable response body: #{e.message}", retryable: true)
    end

    # A response echoing a different batch_id cannot be reconciled with this
    # request's rows, so its results must not be trusted.
    def verify_batch_echo!(parsed, batch_id)
      echoed = parsed[:batch_id]
      return if echoed.nil? || echoed == batch_id

      raise DeliveryError.new("response batch_id mismatch: expected #{batch_id}, got #{echoed}", retryable: true)
    end

    def verify_contract_version!(parsed)
      echoed = parsed[:contract_version]
      return if echoed.nil? || echoed == CONTRACT_VERSION

      raise DeliveryError.new(
        "response contract_version mismatch: expected #{CONTRACT_VERSION}, got #{echoed}",
        retryable: true
      )
    end

    def extract_results(parsed)
      results = parsed[:results]
      raise DeliveryError.new("unexpected response body: results must be an array of objects", retryable: true) unless results.is_a?(Array) && results.all?(Hash)

      results
    end

    # The contract guarantees accepted + replayed + rejected == results.length and
    # exactly one result per submitted row, so the outbox can be reconciled from
    # the response alone; a 200 body that breaks either invariant must not be
    # trusted to update outbox state.
    def verify_result_counts!(parsed, results, rows)
      counts = parsed.values_at(:accepted, :replayed, :rejected)
      return if counts.all?(Integer) && counts.sum == results.length && results.length == rows.length

      raise DeliveryError.new(
        "unreconcilable response: counts #{counts.inspect} do not match #{results.length} result(s) for #{rows.length} submitted row(s)",
        retryable: true
      )
    end

    def build_entry_result(entry, row)
      return missing_result(entry) if row.nil?

      status = validated_result_status(row[:status])
      verify_record_kind!(entry, row)
      EntryResult.new(
        entry: entry,
        status:,
        retryable: row[:retryable],
        error_code: row[:error_code],
        message: row[:message]
      )
    end

    # Each result's record_kind mirrors the top-level array the row was
    # submitted in; a mismatch means the response cannot be reconciled with
    # this request's rows and must not drive outbox state changes.
    def verify_record_kind!(entry, row)
      kind = row[:record_kind]
      return if kind.nil? || kind == entry.record_kind

      raise DeliveryError.new(
        "unreconcilable response: record_kind mismatch for #{entry.idempotency_key}: " \
        "expected #{entry.record_kind.inspect}, got #{kind.inspect}",
        retryable: true
      )
    end

    # Delivery state for the row is ambiguous when the response omits its
    # result, so it stays retryable; ingestion idempotency makes the retry safe.
    def missing_result(entry)
      EntryResult.new(entry:, status: "rejected", retryable: true,
                      error_code: "missing_result", message: "no result returned for this entry")
    end

    def validated_result_status(status)
      return status if VALID_RESULT_STATUSES.include?(status)

      raise DeliveryError.new("unreconcilable response: unknown result status #{status.inspect}", retryable: true)
    end
  end

  # Raised when the HTTP layer fails in a way that prevents row-level result parsing.
  class DeliveryError < StandardError
    attr_reader :retryable

    def initialize(message, retryable:)
      super(message)
      @retryable = retryable
    end
  end
end
