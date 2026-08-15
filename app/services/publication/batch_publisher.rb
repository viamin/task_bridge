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

    EntryResult = Struct.new(:entry, :status, :retryable, :error_code, :message, keyword_init: true) do
      def accepted?  = status == "accepted"
      def replayed?  = status == "replayed"
      def rejected?  = status == "rejected"
    end

    attr_reader :endpoint, :api_key, :publisher_instance

    def initialize(endpoint:, api_key:, publisher_instance: nil)
      @endpoint          = endpoint
      @api_key           = api_key
      @publisher_instance = publisher_instance
    end

    # Publishes outbox entries as a single HTTP batch.
    #
    # Returns an array of EntryResult, one per submitted entry, in submission order.
    # Raises Publication::DeliveryError on unrecoverable transport failures.
    def publish(entries)
      rows = Array(entries)
      raise ArgumentError, "entries must not be empty" if rows.empty?

      batch_id  = SecureRandom.uuid
      sent_at   = Time.current.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
      body      = build_body(rows, batch_id:, sent_at:)
      headers   = build_headers(batch_id:, sent_at:)

      response = post_batch(body:, headers:)
      handle_response(response, rows)
    end

    private

    def build_body(rows, batch_id:, sent_at:)
      grouped = rows.group_by(&:record_kind)

      {
        contract_version: CONTRACT_VERSION,
        batch: { batch_id:, sent_at:, publisher: "task_bridge", publisher_instance: }.compact,
        items: serialize_group(grouped["item"]),
        observations: serialize_group(grouped["observation"]),
        mappings: serialize_group(grouped["mapping"]),
        sync_runs: serialize_group(grouped["sync_run"])
      }.to_json
    end

    def serialize_group(entries)
      Array(entries).map { |e| e.parsed_payload.merge(published_at: Time.current.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")) }
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
        timeout: DEFAULT_TIMEOUT
      )
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError => e
      raise DeliveryError.new("transport error: #{e.message}", retryable: true)
    end

    def handle_response(response, rows)
      case response.code
      when 200
        parse_row_results(response, rows)
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

    def parse_row_results(response, rows)
      parsed = JSON.parse(response.body, symbolize_names: true)
      results_by_key = Array(parsed[:results]).index_by { |r| r[:idempotency_key] }

      rows.map do |entry|
        row = results_by_key[entry.idempotency_key]
        if row
          EntryResult.new(
            entry: entry,
            status: row[:status],
            retryable: row[:retryable],
            error_code: row[:error_code],
            message: row[:message]
          )
        else
          EntryResult.new(entry:, status: "rejected", retryable: false,
                          error_code: "missing_result", message: "no result returned for this entry")
        end
      end
    rescue JSON::ParserError => e
      raise DeliveryError.new("unparseable response body: #{e.message}", retryable: true)
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
