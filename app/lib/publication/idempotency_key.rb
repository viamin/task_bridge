# frozen_string_literal: true

module Publication
  # Builds deterministic record-level idempotency keys for the v1 contract.
  #
  # Format: tb:v1:<record_kind>:<service_instance>:<external_id>:<event_type_or_kind>:<observed_at>
  #
  # Keys are stable across retries because the same published fact always produces the
  # same key. Only transport metadata (batch headers, published_at) may change on retry.
  class IdempotencyKey
    PREFIX = "tb:v1"

    # Returns the key for an item snapshot.
    def self.for_item(service_instance:, external_id:, observed_at:)
      require_presence!(service_instance:, external_id:)
      "#{PREFIX}:item:#{service_instance}:#{external_id}:snapshot:#{format_timestamp(observed_at)}"
    end

    # Returns the key for an observation event.
    def self.for_observation(service_instance:, external_id:, event_type:, observed_at:)
      require_presence!(service_instance:, external_id:, event_type:)
      "#{PREFIX}:obs:#{service_instance}:#{external_id}:#{event_type}:#{format_timestamp(observed_at)}"
    end

    # Returns the key for a mapping membership fact.
    # Successive facts about the same membership must use different observed_at values
    # so keys remain distinct for each confidence transition.
    def self.for_mapping(sync_collection_id:, service_instance:, external_id:, observed_at:)
      require_presence!(sync_collection_id:, service_instance:, external_id:)
      "#{PREFIX}:map:sync_collection:#{sync_collection_id}:membership:" \
        "#{service_instance}:#{external_id}:#{format_timestamp(observed_at)}"
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

    # Blank segments would produce malformed keys that cannot be recalled once
    # accepted by TaskBridge Web, so they are rejected at build time.
    def self.require_presence!(**fields)
      blank = fields.select { |_, value| value.blank? }
      raise ArgumentError, "blank key segment(s): #{blank.keys.join(', ')}" if blank.any?
    end
    private_class_method :require_presence!
  end
end
