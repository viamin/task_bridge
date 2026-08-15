# frozen_string_literal: true

module Publication
  # Assembles the batch envelope for a single HTTP push to TaskBridge Web.
  #
  # A batch must contain at least one record across items, observations, mappings,
  # and sync_runs. Empty batches must not be sent. All arrays are independent;
  # omitted arrays are equivalent to empty arrays on the receiving end.
  #
  # Contract rules enforced here:
  # - batch_id and sent_at are required envelope fields.
  # - No idempotency_key may appear more than once across all arrays.
  # - At least one record must be present.
  class Batch
    CONTRACT_VERSION = 1

    attr_reader :batch_id, :sent_at, :publisher, :publisher_instance,
                :items, :observations, :mappings, :sync_runs

    def initialize(
      batch_id:,
      sent_at:,
      items: [],
      observations: [],
      mappings: [],
      sync_runs: [],
      publisher: "task_bridge",
      publisher_instance: nil
    )
      @batch_id = batch_id
      @sent_at = sent_at
      @items = Array(items)
      @observations = Array(observations)
      @mappings = Array(mappings)
      @sync_runs = Array(sync_runs)
      @publisher = publisher
      @publisher_instance = publisher_instance

      validate!
    end

    def to_payload
      {
        contract_version: CONTRACT_VERSION,
        batch: batch_envelope,
        items: items.map(&:to_payload),
        observations: observations.map(&:to_payload),
        mappings: mappings.map(&:to_payload),
        sync_runs: sync_runs.map(&:to_payload)
      }
    end

    def total_record_count
      items.length + observations.length + mappings.length + sync_runs.length
    end

    private

    def batch_envelope
      envelope = {
        batch_id:,
        sent_at: format_timestamp(sent_at),
        publisher:
      }
      envelope[:publisher_instance] = publisher_instance if publisher_instance
      envelope
    end

    def validate!
      raise ArgumentError, "batch_id is required" if batch_id.blank?
      raise ArgumentError, "sent_at is required" if sent_at.nil?
      raise ArgumentError, "batch must contain at least one record" if total_record_count.zero?

      check_duplicate_idempotency_keys!
    end

    def all_records
      [*items, *observations, *mappings, *sync_runs]
    end

    def check_duplicate_idempotency_keys!
      keys = all_records.map(&:idempotency_key)
      duplicates = keys.tally.select { |_, count| count > 1 }.keys
      raise ArgumentError, "duplicate idempotency_key(s) in batch: #{duplicates.join(', ')}" if duplicates.any?
    end

    def format_timestamp(value)
      return nil if value.nil?
      return value if value.is_a?(String)

      value.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
    end
  end
end
