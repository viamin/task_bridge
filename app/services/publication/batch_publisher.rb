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
  #     entry = entry_result.entry
  #     entry.mark_delivered! if entry_result.accepted?
  #     entry.mark_replayed! if entry_result.replayed?
  #     next unless entry_result.rejected?
  #
  #     if entry_result.retryable
  #       entry.mark_failed!(message: entry_result.message)
  #     else
  #       entry.mark_terminal!(message: entry_result.message)
  #     end
  #   end
  #
  # Deliberately larger than the ~100-line class target: request building,
  # transport error classification, and response reconciliation form one
  # delivery boundary, and splitting them would pass the same request context
  # through several objects without reducing the complexity.
  class BatchPublisher
    DEFAULT_TIMEOUT = 30 # seconds
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
      # Encoding is checked first because blank? itself raises on invalid
      # byte sequences; a malformed endpoint or key must fail with a clear
      # error instead of an opaque one at construction time.
      Utf8.validate_fields!({ endpoint:, api_key:, publisher_instance: })
      raise ArgumentError, "endpoint is required" if endpoint.blank?
      raise ArgumentError, "endpoint must be a valid http(s) URI" unless valid_endpoint_uri?(endpoint)
      raise ArgumentError, "api_key is required" if api_key.blank?
      raise ArgumentError, "publisher_instance must be a non-blank string when provided" if invalid_envelope_string?(publisher_instance)
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

      check_entry_interface!(rows)

      unknown = rows.map(&:record_kind).uniq - RECORD_KINDS
      raise ArgumentError, "unknown record_kind(s): #{unknown.join(', ')}" if unknown.any?

      check_duplicate_idempotency_keys!(rows)
      check_payload_contract_versions!(rows)
      check_payload_idempotency_keys!(rows)

      # One publish attempt is described by a single instant: deriving both
      # stamps from the same Time.current keeps published_at from landing
      # microsecond-before the envelope's sent_at across a clock tick.
      attempt_time = Time.current
      batch_id     = SecureRandom.uuid
      sent_at      = Timestamp.format(attempt_time)
      published_at = Timestamp.format(attempt_time)
      body         = build_body(rows, batch_id:, sent_at:, published_at:)
      headers      = build_headers(batch_id:, sent_at:)

      response = post_batch(body:, headers:)
      handle_response(response, rows, batch_id:)
    end

    private

    # publisher_instance is envelope metadata; nil means omit, and any other
    # type would publish a contract field with the wrong shape.
    def invalid_envelope_string?(value)
      !(value.nil? || (value.is_a?(String) && value.present?))
    end

    # Fail fast on a misconfigured endpoint instead of surfacing an opaque
    # transport error (or an unhandled URI parse crash) at publish time.
    def valid_endpoint_uri?(value)
      uri = URI.parse(value)
      uri.is_a?(URI::HTTP) && uri.host.present?
    rescue URI::Error
      false
    end

    # A wrong-typed entry would otherwise crash the record_kind check with an
    # opaque NoMethodError instead of a clear error naming the problem.
    def check_entry_interface!(rows)
      interface = %i[record_kind idempotency_key parsed_payload]
      return if rows.all? { |row| interface.all? { |method| row.respond_to?(method) } }

      raise ArgumentError, "entries must respond to #{interface.join(', ')}"
    end

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
      mismatched = rows.reject { |row| payload_hash(row)[:contract_version] == CONTRACT_VERSION }
      return if mismatched.empty?

      keys = mismatched.map(&:idempotency_key).join(", ")
      raise ArgumentError, "payload contract_version must be #{CONTRACT_VERSION} for idempotency_key(s): #{keys}"
    end

    # A row whose stored payload identity does not match its outbox column can
    # never be reconciled from the response (results echo the payload key) and
    # would retry forever, so it is rejected before any bytes are sent.
    def check_payload_idempotency_keys!(rows)
      mismatched = rows.reject { |row| payload_hash(row)[:idempotency_key] == row.idempotency_key }
      return if mismatched.empty?

      keys = mismatched.map(&:idempotency_key).join(", ")
      raise ArgumentError, "payload idempotency_key must match the outbox row for idempotency_key(s): #{keys}"
    end

    def payload_hash(row)
      parsed = row.parsed_payload
      raise ArgumentError, "payload for #{row.idempotency_key} must be a JSON object" unless parsed.is_a?(Hash)

      parsed
    rescue TypeError => e
      # JSON.parse raises TypeError (not ParserError) when payload is nil or
      # not a string, for example on an entry that was never persisted.
      raise ArgumentError, "payload for #{row.idempotency_key} is missing or unreadable: #{e.message}"
    rescue JSON::ParserError => e
      raise ArgumentError, "unparseable payload for #{row.idempotency_key}: #{e.message}"
    end

    def build_body(rows, batch_id:, sent_at:, published_at:)
      grouped = rows.group_by(&:record_kind)

      begin
        {
          contract_version: CONTRACT_VERSION,
          batch: { batch_id:, sent_at:, publisher: "task_bridge", publisher_instance: }.compact,
          items: serialize_group(grouped["item"], published_at:),
          observations: serialize_group(grouped["observation"], published_at:),
          mappings: serialize_group(grouped["mapping"], published_at:),
          sync_runs: serialize_group(grouped["sync_run"], published_at:)
        }.to_json
      rescue JSON::GeneratorError => e
        raise_unserializable_rows!(rows, published_at:, cause: e)
      end
    end

    # JSON.parse accepts malformed UTF-8 byte sequences, so a row written past
    # the model validation (raw SQL, update_column) can pass every pre-send
    # check and still fail JSON generation when the body is assembled. The
    # envelope itself is always ASCII-safe, so generation can only fail on a
    # row payload: identify the offender(s) and raise the same error the model
    # raises at write time instead of leaking a GeneratorError.
    def raise_unserializable_rows!(rows, published_at:, cause:)
      keys = rows.reject { |row| serializable_payload?(row, published_at:) }.map(&:idempotency_key)
      raise ArgumentError, "payload for #{keys.join(', ')} is not serializable: #{cause.message}"
    end

    def serializable_payload?(row, published_at:)
      JSON.generate(payload_hash(row).merge(published_at:))
      true
    rescue JSON::GeneratorError
      false
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
           SystemCallError,
           HTTParty::Error => e
      # SystemCallError covers every Errno::* network failure (ECONNREFUSED,
      # ECONNRESET, EHOSTUNREACH, ETIMEDOUT, EPIPE, ENETUNREACH, ...).
      # HTTParty::Error covers httparty-specific failures such as
      # RedirectionTooDeep (redirect loop at the endpoint).
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
        # Unexpected statuses (for example a 204 or 3xx without the contract
        # result body) leave row delivery state ambiguous, and retrying is safe
        # under idempotent ingestion: accepted rows replay rather than
        # duplicate. Other client errors stay terminal until the request or
        # configuration is fixed.
        raise DeliveryError.new(
          "unexpected response (#{response.code}): #{response.body}",
          retryable: response.code < 400 || response.code >= 500
        )
      end
    end

    def parse_row_results(response, rows, batch_id:)
      # to_s coerces a nil body (empty responses from proxies and load
      # balancers) into "", which JSON.parse rejects with ParserError; a raw
      # nil would raise TypeError and bypass the classification below.
      parsed = JSON.parse(response.body.to_s, symbolize_names: true)
      raise DeliveryError.new("unexpected response body: expected a JSON object", retryable: true) unless parsed.is_a?(Hash)

      verify_batch_echo!(parsed, batch_id)
      verify_contract_version!(parsed)

      results = extract_results(parsed)
      verify_result_counts!(parsed, results, rows)
      results_by_key = index_results_by_key(results)

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

      verify_result_keys_present!(results)
      results
    end

    # Each result must carry its idempotency_key so it can be matched back to
    # the submitted row; a result missing this field can never be reconciled
    # and would otherwise silently orphan the row it was meant to describe.
    def verify_result_keys_present!(results)
      return if results.all? { |result| result[:idempotency_key].present? }

      raise DeliveryError.new("unreconcilable response: result missing idempotency_key", retryable: true)
    end

    # The contract returns exactly one result per submitted row; a response
    # repeating an idempotency_key cannot be reconciled unambiguously, so it
    # must not drive outbox state changes.
    def index_results_by_key(results)
      duplicates = results.map { |result| result[:idempotency_key] }.tally.select { |_, count| count > 1 }.keys
      return results.index_by { |result| result[:idempotency_key] } if duplicates.empty?

      raise DeliveryError.new(
        "unreconcilable response: duplicate idempotency_key(s) in results: #{duplicates.inspect}",
        retryable: true
      )
    end

    # The contract guarantees accepted + replayed + rejected == results.length and
    # exactly one result per submitted row, so the outbox can be reconciled from
    # the response alone; a 200 body that breaks either invariant must not be
    # trusted to update outbox state.
    def verify_result_counts!(parsed, results, rows)
      counts = parsed.values_at(:accepted, :replayed, :rejected)
      return if counts.all? { |count| count.is_a?(Integer) && count >= 0 } &&
                counts.sum == results.length && results.length == rows.length

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
        status: status,
        retryable: validated_retryable(row[:retryable], status:),
        error_code: row[:error_code],
        message: row[:message]
      )
    end

    # retryable drives outbox retry classification, so a non-boolean value from
    # a misbehaving server must not silently flip that decision. The contract
    # requires retry guidance per failed row, so rejected results must carry it.
    def validated_retryable(value, status:)
      return value if [true, false].include?(value)
      return nil unless status == "rejected"

      raise DeliveryError.new(
        "unreconcilable response: rejected result must carry a boolean retryable, got #{value.inspect}",
        retryable: true
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
end
