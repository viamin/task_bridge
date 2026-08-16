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
    # Remote bodies are embedded in DeliveryError messages (and later persisted
    # through the outbox error_message column, which truncates at 1000); a
    # smaller bound here keeps the full message well under that limit no matter
    # how large the remote error page is.
    RESPONSE_EXCERPT_MAX = 500
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
      # A wrong-typed endpoint must fail here with a clear error instead of
      # reaching URI parsing, which only stringifies non-string values.
      raise ArgumentError, "endpoint must be a string" unless endpoint.is_a?(String)
      raise ArgumentError, "endpoint must be a valid http(s) URI" unless valid_endpoint_uri?(endpoint)
      raise ArgumentError, "api_key is required" if api_key.blank?
      # The key is interpolated into the Authorization header, so anything but
      # a string would be silently coerced into a bogus credential.
      raise ArgumentError, "api_key must be a string" unless api_key.is_a?(String)
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

      # empty? (not any?) because a nil record_kind element is not truthy and
      # would otherwise slip past this guard into the group_by below.
      unknown = rows.map(&:record_kind).uniq - RECORD_KINDS
      raise ArgumentError, "unknown record_kind(s): #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?

      check_idempotency_keys_present!(rows)
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
      uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil?
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

    # A row without a non-blank string idempotency_key can never be reconciled:
    # results echo the payload key, so a keyless row would fail the whole batch
    # with an unreconcilable response.
    # A single nil or "" key is not a duplicate and nil == nil satisfies the
    # payload-key match, so presence needs its own guard. present? raises on
    # invalid UTF-8, so encoding is verified first.
    def check_idempotency_keys_present!(rows)
      blank = rows.reject { |row| present_idempotency_key?(row.idempotency_key) }
      return if blank.empty?

      raise ArgumentError, "entries must carry a non-blank string idempotency_key"
    end

    def present_idempotency_key?(key)
      key.is_a?(String) && key.valid_encoding? && key.present?
    end

    # The contract forbids repeating an idempotency_key within a batch. The
    # outbox unique index normally prevents this, but the publisher guards any
    # caller-supplied entry collection.
    def check_duplicate_idempotency_keys!(rows)
      duplicates = rows.map(&:idempotency_key).tally.select { |_, count| count > 1 }.keys
      return if duplicates.empty?

      raise ArgumentError, "duplicate idempotency_key(s) in batch: #{duplicates.map(&:inspect).join(', ')}"
    end

    # The contract requires every row's contract_version to equal the batch's,
    # so a row persisted under a different major version must never be silently
    # sent through a v1 batch. Corrupt payloads fail here with a clear error
    # naming the offending row instead of a raw JSON or type error later.
    # The Integer check rejects JSON 1.0: Ruby numeric equality would let the
    # Float through, only for the row to face a remote non-retryable rejection.
    def check_payload_contract_versions!(rows)
      mismatched = rows.reject { |row| canonical_contract_version?(payload_value(row, :contract_version)) }
      return if mismatched.empty?

      keys = mismatched.map(&:idempotency_key).join(", ")
      raise ArgumentError, "payload contract_version must be #{CONTRACT_VERSION} for idempotency_key(s): #{keys}"
    end

    def canonical_contract_version?(version)
      version.is_a?(Integer) && version == CONTRACT_VERSION
    end

    # A row whose stored payload identity does not match its outbox column can
    # never be reconciled from the response (results echo the payload key) and
    # would retry forever, so it is rejected before any bytes are sent.
    def check_payload_idempotency_keys!(rows)
      mismatched = rows.reject { |row| payload_value(row, :idempotency_key) == row.idempotency_key }
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
      # Parser messages quote the offending payload region, and a row written
      # past the model validation can carry malformed bytes there, so the
      # message is scrubbed before it reaches callers that log it.
      raise ArgumentError, "unparseable payload for #{row.idempotency_key}: #{Utf8.sanitize(e.message)}"
    end

    def payload_value(row, field)
      Publication::HashAccess.fetch(payload_hash(row), field)
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
      rescue JSON::GeneratorError, JSON::NestingError => e
        # NestingError is a ParserError subclass, not a GeneratorError: a row
        # nested exactly at the JSON parse limit is storable and parses fine,
        # yet exceeds the generation limit once the envelope wraps it.
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
      # Rows are serialized inside a top-level batch array, so each row is
      # probed at its embedded depth; every record group (items, observations,
      # mappings, sync_runs) is a top-level array, so one wrapper key reproduces
      # the depth of any group faithfully.
      JSON.generate(items: [payload_hash(row).merge(published_at:)])
      true
    rescue JSON::GeneratorError, JSON::NestingError
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
    rescue Timeout::Error, SocketError, EOFError,
           OpenSSL::SSL::SSLError,
           SystemCallError,
           Net::ProtocolError, Net::HTTPBadResponse,
           Zlib::Error,
           HTTParty::Error => e
      # Timeout::Error catches timeout exceptions that escape the HTTP stack
      # without the more specific net/http subclasses.
      # SystemCallError covers every Errno::* network failure (ECONNREFUSED,
      # ECONNRESET, EHOSTUNREACH, ETIMEDOUT, EPIPE, ENETUNREACH, ...).
      # HTTParty::Error covers httparty-specific failures such as
      # RedirectionTooDeep (redirect loop at the endpoint).
      # Net::ProtocolError (with its Proto* subclasses) and
      # Net::HTTPBadResponse are raised by net/http itself when a proxy or
      # misbehaving server answers with malformed HTTP; Zlib::Error escapes
      # net/http's transparent gzip inflater on corrupt compressed bodies.
      raise DeliveryError.new("transport error: #{e.message}", retryable: true)
    end

    def handle_response(response, rows, batch_id:)
      code = parsed_response_code(response)

      case code
      when 200
        parse_row_results(response, rows, batch_id:)
      when 400, 422
        raise DeliveryError.new("request rejected (#{response.code}): #{response_excerpt(response)}", retryable: false)
      when 401
        raise DeliveryError.new("authentication failure (401): check API key", retryable: false)
      when 409
        # The conflict body names the offending key, so the scrubbed excerpt is
        # included for operator debugging like the other terminal rejections.
        raise DeliveryError.new(
          "batch conflict (409): duplicate idempotency key payload mismatch: #{response_excerpt(response)}",
          retryable: false
        )
      when 413
        raise DeliveryError.new("payload too large (413): reduce batch size", retryable: true)
      when 429
        raise DeliveryError.new("rate limited (429): back off and retry", retryable: true)
      when 408
        # 408 is the server giving up while waiting for the request: a
        # transient condition like 429, and retry is safe under idempotent
        # ingestion, so it must not park rows in terminal state.
        raise DeliveryError.new("request timeout (408): retry", retryable: true)
      else
        # Unexpected statuses (for example a 204 or 3xx without the contract
        # result body) leave row delivery state ambiguous, and retrying is safe
        # under idempotent ingestion: accepted rows replay rather than
        # duplicate. Other client errors stay terminal until the request or
        # configuration is fixed.
        raise DeliveryError.new(
          "unexpected response (#{response.code}): #{response_excerpt(response)}",
          retryable: code.nil? || code < 400 || code >= 500
        )
      end
    end

    # HTTParty/Net::HTTP expose status codes as strings. Parse once here so the
    # transport policy applies to real responses instead of falling through every
    # numeric branch and misclassifying successful or terminal outcomes.
    def parsed_response_code(response)
      Integer(response.code, exception: false)
    end

    # Remote bodies (proxy error pages, misbehaving servers) can carry bytes
    # that are not valid UTF-8 and can be arbitrarily large; scrubbing keeps
    # the embedded excerpt safe to log and to persist through the outbox
    # error_message column, and truncation bounds the message regardless of
    # what the remote sent back.
    def response_excerpt(response)
      sanitize_remote_text(response.body.to_s).truncate(RESPONSE_EXCERPT_MAX)
    end

    # Remote text is embedded in DeliveryError messages and EntryResults that
    # callers log and persist, and a misbehaving endpoint (echo handler,
    # debugging proxy) can reflect the request's own Authorization value back
    # in a body or row message, so the credential is redacted wherever remote
    # text crosses that boundary. gsub with a String pattern is a literal
    # match, so key bytes with regex meaning are safe. nil passes through so
    # accepted rows keep absent error fields rather than empty strings.
    def redact_credentials(text)
      return if text.nil?

      text.to_s.gsub(api_key, "[REDACTED]")
    end

    # Remote text crosses the same logging/persistence boundary as sync-run
    # operational detail, so it needs the broader header/cookie/secret
    # redaction rules in addition to literal API-key replacement.
    def sanitize_remote_text(value)
      redact_credentials(OperationalText.sanitize(value))
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
      verify_result_key_set!(rows, results_by_key)
      verify_result_order!(rows, results)

      rows.map { |entry| build_entry_result(entry, results_by_key[entry.idempotency_key]) }
    rescue JSON::ParserError => e
      raise DeliveryError.new("unparseable response body: #{sanitize_remote_text(e.message)}", retryable: true)
    end

    # A response echoing a different batch_id cannot be reconciled with this
    # request's rows, so its results must not be trusted. The echoed value is
    # remote text and can carry invalid UTF-8 past JSON parsing, so it is
    # inspected (escaping malformed bytes) instead of interpolated raw.
    def verify_batch_echo!(parsed, batch_id)
      echoed = parsed[:batch_id]
      return if echoed == batch_id

      raise DeliveryError.new("response batch_id missing or mismatched: expected #{batch_id}, got #{echoed.inspect}", retryable: true)
    end

    def verify_contract_version!(parsed)
      echoed = parsed[:contract_version]
      return if canonical_contract_version?(echoed)

      raise DeliveryError.new(
        "response contract_version missing or mismatched: expected #{CONTRACT_VERSION}, got #{echoed.inspect}",
        retryable: true
      )
    end

    def extract_results(parsed)
      results = parsed[:results]
      raise DeliveryError.new("unexpected response body: results must be an array of objects", retryable: true) unless results.is_a?(Array) && results.all?(Hash)

      verify_result_keys_present!(results)
      verify_result_record_kinds!(results)
      verify_result_statuses!(results)
      results
    end

    # Each result must carry its idempotency_key so it can be matched back to
    # the submitted row; a result missing this field can never be reconciled
    # and would otherwise silently orphan the row it was meant to describe.
    # present? itself raises on malformed UTF-8, and the response is remote
    # data, so validity and presence are checked without it.
    def verify_result_keys_present!(results)
      return if results.all? { |result| result_key_present?(result[:idempotency_key]) }

      raise DeliveryError.new("unreconcilable response: result missing idempotency_key", retryable: true)
    end

    def result_key_present?(key)
      return false unless key.is_a?(String) && key.valid_encoding?

      !key.strip.empty?
    end

    # Each result must echo the contract record_kind so the row can be checked
    # against the top-level array it was submitted in. Missing or invalid kinds
    # would otherwise let a malformed 200 body drive outbox state changes.
    def verify_result_record_kinds!(results)
      invalid = results.map { |result| result[:record_kind] }.reject { |kind| RECORD_KINDS.include?(kind) }.uniq
      return if invalid.empty?

      raise DeliveryError.new(
        "unreconcilable response: result record_kind must be one of #{RECORD_KINDS.join(', ')}, got #{invalid.first.inspect}",
        retryable: true
      )
    end

    # Statuses are validated before the count cross-check so a response whose
    # declared counts disagree with its own per-row statuses is detected as
    # unreconcilable rather than passing the sum check alone.
    def verify_result_statuses!(results)
      invalid = results.map { |result| result[:status] }.reject { |status| VALID_RESULT_STATUSES.include?(status) }.uniq
      return if invalid.empty?

      raise DeliveryError.new("unreconcilable response: unknown result status #{invalid.first.inspect}", retryable: true)
    end

    # The contract requires one result per submitted row in submission order.
    # Key-based reconciliation is still used afterward for clarity and to catch
    # duplicates/extras precisely, but an out-of-order 200 body is still a
    # contract violation and should be surfaced immediately.
    def verify_result_order!(rows, results)
      submitted_keys = rows.map(&:idempotency_key)
      response_keys = results.map { |result| result[:idempotency_key] }
      return if response_keys == submitted_keys

      raise DeliveryError.new(
        "unreconcilable response: results are not in submission order",
        retryable: true
      )
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

    # A 200 response is trustworthy only when its results map exactly onto the
    # submitted rows. Matching counts are not enough: an unexpected key would
    # otherwise be ignored while a submitted row was actually missing.
    def verify_result_key_set!(rows, results_by_key)
      submitted_keys = rows.map(&:idempotency_key)
      response_keys = results_by_key.keys
      missing = submitted_keys - response_keys
      extra = response_keys - submitted_keys
      return if missing.empty? && extra.empty?

      problems = []
      problems << "missing #{missing.inspect}" if missing.any?
      problems << "unexpected #{extra.inspect}" if extra.any?
      raise DeliveryError.new(
        "unreconcilable response: result idempotency_key set mismatch (#{problems.join('; ')})",
        retryable: true
      )
    end

    # The contract guarantees accepted + replayed + rejected == results.length and
    # exactly one result per submitted row, so the outbox can be reconciled from
    # the response alone; a 200 body that breaks either invariant must not be
    # trusted to update outbox state. Each declared count must also match the
    # number of results carrying that status: counts that merely sum correctly
    # while contradicting the per-row statuses are still unreconcilable.
    def verify_result_counts!(parsed, results, rows)
      counts = declared_result_counts(parsed)
      return if counts.values.all? { |count| count.is_a?(Integer) && count >= 0 } &&
                counts.values.sum == results.length && results.length == rows.length &&
                declared_counts_match?(counts, results)

      raise DeliveryError.new(
        "unreconcilable response: counts #{counts.values.inspect} do not match #{results.length} result(s) for #{rows.length} submitted row(s)",
        retryable: true
      )
    end

    def declared_result_counts(parsed)
      {
        "accepted" => parsed[:accepted],
        "replayed" => parsed[:replayed],
        "rejected" => parsed[:rejected]
      }
    end

    def declared_counts_match?(counts, results)
      VALID_RESULT_STATUSES.all? do |status|
        declared = counts.fetch(status)
        results.count { |result| result[:status] == status } == declared
      end
    end

    def build_entry_result(entry, row)
      verify_record_kind!(entry, row)
      status = row[:status]
      EntryResult.new(
        entry: entry,
        status:,
        retryable: validated_retryable(row[:retryable], status:),
        error_code: validated_error_code(row[:error_code], status:),
        message: validated_message(row[:message], status:)
      )
    end

    # retryable drives outbox retry classification, so a non-boolean value from
    # a misbehaving server must not silently flip that decision. The contract
    # requires retry guidance per failed row, so rejected results must carry it.
    def validated_retryable(value, status:)
      return value if [true, false].include?(value)
      return nil if value.nil? && status != "rejected"

      if status == "rejected"
        raise DeliveryError.new(
          "unreconcilable response: rejected result must carry a boolean retryable, got #{value.inspect}",
          retryable: true
        )
      end

      raise DeliveryError.new(
        "unreconcilable response: result retryable must be a boolean when provided, got #{value.inspect}",
        retryable: true
      )
    end

    # Rejected rows require a machine-readable error_code so callers can
    # classify the failure without scraping free text. Any present error_code
    # on accepted/replayed rows must still be a string so a malformed 200 body
    # does not silently coerce arbitrary JSON values into bogus codes.
    def validated_error_code(value, status:)
      return nil if value.nil? && status != "rejected"
      return sanitize_non_blank_response_text(value, field: :error_code, status:) if value.is_a?(String)

      if status == "rejected"
        raise DeliveryError.new(
          "unreconcilable response: rejected result must carry a non-blank string error_code, got #{value.inspect}",
          retryable: true
        )
      end

      raise DeliveryError.new(
        "unreconcilable response: result error_code must be a string when provided, got #{value.inspect}",
        retryable: true
      )
    end

    # Row-level message is optional, but when present it crosses the same log
    # and persistence boundary as error_code and must therefore keep the
    # contract string shape instead of being silently coerced from arbitrary
    # JSON types.
    def validated_message(value, status:)
      return nil if value.nil?
      return sanitize_response_text(value) if value.is_a?(String)

      if status == "rejected"
        raise DeliveryError.new(
          "unreconcilable response: rejected result message must be a string when provided, got #{value.inspect}",
          retryable: true
        )
      end

      raise DeliveryError.new(
        "unreconcilable response: result message must be a string when provided, got #{value.inspect}",
        retryable: true
      )
    end

    def sanitize_non_blank_response_text(value, field:, status:)
      sanitized = sanitize_response_text(value)
      return sanitized unless sanitized.strip.empty?

      if status == "rejected"
        raise DeliveryError.new(
          "unreconcilable response: rejected result must carry a non-blank string #{field}, got #{value.inspect}",
          retryable: true
        )
      end

      raise DeliveryError.new(
        "unreconcilable response: result #{field} must be a non-blank string when provided, got #{value.inspect}",
        retryable: true
      )
    end

    def sanitize_response_text(value)
      sanitize_remote_text(value)
    end

    # Each result's record_kind mirrors the top-level array the row was
    # submitted in; a mismatch means the response cannot be reconciled with
    # this request's rows and must not drive outbox state changes.
    def verify_record_kind!(entry, row)
      kind = row[:record_kind]
      return if kind == entry.record_kind

      raise DeliveryError.new(
        "unreconcilable response: record_kind mismatch for #{entry.idempotency_key}: " \
        "expected #{entry.record_kind.inspect}, got #{kind.inspect}",
        retryable: true
      )
    end
  end
end
