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
      {
        batch_id:,
        sent_at: Timestamp.format(sent_at),
        publisher:,
        publisher_instance:
      }.compact
    end

    def validate!
      # Encoding is checked first because blank? itself raises on invalid
      # byte sequences, and malformed envelope strings would crash JSON
      # generation in the publisher.
      Utf8.validate_fields!({ batch_id:, sent_at:, publisher:, publisher_instance: })
      raise ArgumentError, "batch_id is required" if batch_id.blank?
      raise ArgumentError, "batch_id must be a string" unless batch_id.is_a?(String)
      raise ArgumentError, "sent_at is required" if sent_at.blank?
      raise ArgumentError, "batch must contain at least one record" if total_record_count.zero?

      check_record_interface!
      check_envelope_strings!
      Timestamp.validate!(sent_at)
      check_duplicate_idempotency_keys!
    end

    def all_records
      [*items, *observations, *mappings, *sync_runs]
    end

    # A wrong-typed entry (anything coerced by Array that is not a record)
    # would otherwise crash the duplicate-key check with an opaque
    # NoMethodError, so the record interface is verified up front.
    def check_record_interface!
      invalid = all_records.reject { |record| record.respond_to?(:idempotency_key) && record.respond_to?(:to_payload) }
      return if invalid.empty?

      raise ArgumentError, "batch entries must implement idempotency_key and to_payload"
    end

    # publisher and publisher_instance are envelope metadata strings; nil means
    # omit, and any other type would publish a contract field with the wrong
    # shape, so wrong-typed or blank values fail here like every other field.
    def check_envelope_strings!
      check_envelope_string!(publisher, :publisher)
      check_envelope_string!(publisher_instance, :publisher_instance)
    end

    def check_envelope_string!(value, field)
      return if value.nil? || (value.is_a?(String) && value.present?)

      raise ArgumentError, "#{field} must be a non-blank string when provided"
    end

    def check_duplicate_idempotency_keys!
      keys = all_records.map(&:idempotency_key)
      # empty? (not any?) because a nil key element is not truthy and would
      # otherwise slip past this guard; inspect names nil keys in the error.
      duplicates = keys.tally.select { |_, count| count > 1 }.keys
      return if duplicates.empty?

      raise ArgumentError, "duplicate idempotency_key(s) in batch: #{duplicates.map(&:inspect).join(', ')}"
    end
  end
end
