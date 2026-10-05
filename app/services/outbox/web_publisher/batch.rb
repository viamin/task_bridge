# frozen_string_literal: true

module Outbox
  class WebPublisher
    # Builds one versioned batch request (RDR #215) from a set of outbox
    # rows destined for `POST /api/task_bridge/v1/ingestion/batches`.
    # Rows are grouped into the contract's top-level arrays by record
    # kind; each wire row is the row's immutable canonical payload plus
    # transport-only fields (`idempotency_key`, `contract_version`,
    # `published_at`), so retries vary only transport metadata. The batch
    # id is a transport identifier: each attempt mints a fresh one while
    # record-level idempotency keys stay stable.
    class Batch
      ENDPOINT_PATH = "/api/task_bridge/v1/ingestion/batches"
      PUBLISHER = "task_bridge"

      ARRAY_BY_RECORD_KIND = {
        "item" => :items,
        "observation" => :observations,
        "mapping" => :mappings,
        "sync_run" => :sync_runs
      }.freeze

      attr_reader :entries

      def initialize(entries, now: Time.current)
        raise ArgumentError, "cannot publish an empty batch" if entries.blank?
        raise ArgumentError, "cannot publish mixed payload versions" if entries.map(&:payload_version).uniq.many?

        @entries = entries
        @contract_version = entries.first.payload_version
        @batch_id = SecureRandom.uuid
        @sent_at = now.utc.iso8601(6)
      end

      def headers(api_key:)
        {
          "Authorization" => "Bearer #{api_key}",
          "Content-Type" => "application/json",
          "X-TaskBridge-Contract-Version" => contract_version.to_s,
          "X-TaskBridge-Batch-Id" => @batch_id,
          "X-TaskBridge-Sent-At" => @sent_at
        }
      end

      def body
        {
          contract_version:,
          batch: {
            batch_id: @batch_id,
            sent_at: @sent_at,
            publisher: PUBLISHER,
            publisher_instance: publisher_instance
          }
        }.merge(record_arrays)
      end

      def body_json
        JSON.pretty_generate(body)
      end

      private

      attr_reader :contract_version

      def publisher_instance
        Socket.gethostname.to_s.presence || PUBLISHER
      end

      def record_arrays
        ARRAY_BY_RECORD_KIND.values.index_with { [] }.tap do |arrays|
          entries.each { |entry| arrays[ARRAY_BY_RECORD_KIND.fetch(entry.record_kind)] << row(entry) }
        end
      end

      def row(entry)
        entry.payload.deep_stringify_keys
             .merge("idempotency_key" => entry.idempotency_key,
                    "contract_version" => entry.payload_version,
                    "published_at" => @sent_at)
      end
    end
  end
end
