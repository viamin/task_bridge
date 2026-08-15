# frozen_string_literal: true

module Publication
  # Builds deterministic record-level idempotency keys for the v1 contract.
  #
  # Format: tb:v1:<record_kind>:<service_instance>:<external_id>:<event_type_or_kind>:<observed_at_or_sequence>
  #
  # Keys are stable across retries because the same published fact always produces the
  # same key. Only transport metadata (batch headers, published_at) may change on retry.
  #
  # Observation and mapping keys may end with a sequence segment instead of the
  # timestamp when one observed_at covers several facts, per the RDR 215 key format.
  class IdempotencyKey
    PREFIX = "tb:v1"

    # Returns the key for an item snapshot.
    def self.for_item(service_instance:, external_id:, observed_at:)
      require_presence!(service_instance:, external_id:)
      "#{PREFIX}:item:#{service_instance}:#{external_id}:snapshot:#{format_timestamp(observed_at)}"
    end

    # Returns the key for an observation event. Pass sequence: instead of
    # observed_at: when one observation yields several field transitions that
    # share an observed_at, so each row keeps a distinct key.
    def self.for_observation(service_instance:, external_id:, event_type:, observed_at: nil, sequence: nil)
      require_presence!(service_instance:, external_id:, event_type:)
      "#{PREFIX}:obs:#{service_instance}:#{external_id}:#{event_type}:#{key_tail(observed_at:, sequence:)}"
    end

    # Returns the key for a mapping membership fact. Successive facts about the
    # same membership must use distinct keys: a different observed_at, or a
    # sequence when the timestamps collide.
    def self.for_mapping(sync_collection_id:, service_instance:, external_id:, observed_at: nil, sequence: nil)
      require_presence!(sync_collection_id:, service_instance:, external_id:)
      "#{PREFIX}:map:sync_collection:#{sync_collection_id}:membership:" \
        "#{service_instance}:#{external_id}:#{key_tail(observed_at:, sequence:)}"
    end

    # Returns the key for a sync-run summary.
    # Sync-run keys use the run scope in place of item identity.
    def self.for_sync_run(service_instance:, sync_run_id:)
      require_presence!(service_instance:, sync_run_id:)
      "#{PREFIX}:sync_run:#{service_instance}:#{sync_run_id}"
    end

    def self.format_timestamp(value)
      raise ArgumentError, "observed_at is required" if value.blank?

      Timestamp.format(value)
    end
    private_class_method :format_timestamp

    # The key format ends with a single <observed_at_or_sequence> segment, so
    # exactly one of the two may be provided. Numeric sequences are compared
    # after to_s so a valid 0 is not swallowed by blank?.
    def self.key_tail(observed_at:, sequence:)
      raise ArgumentError, "pass observed_at or sequence, not both" if observed_at && sequence
      return format_timestamp(observed_at) if observed_at

      raise ArgumentError, "observed_at or sequence is required" if sequence.nil?
      raise ArgumentError, "sequence must not be blank" if sequence.to_s.empty?

      sequence.to_s
    end
    private_class_method :key_tail

    # Blank segments would produce malformed keys that cannot be recalled once
    # accepted by TaskBridge Web, so they are rejected at build time.
    def self.require_presence!(**fields)
      blank = fields.select { |_, value| value.blank? }
      raise ArgumentError, "blank key segment(s): #{blank.keys.join(', ')}" if blank.any?
    end
    private_class_method :require_presence!
  end
end
