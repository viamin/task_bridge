# frozen_string_literal: true

module Publication
  # Represents an append-only observation fact about what TaskBridge saw or concluded.
  #
  # Observations are not snapshots; they preserve change history. Every v1 observation
  # is item-scoped, so item_key must be present.
  #
  # Required fields: idempotency_key, event_type, observed_at, item_key, source
  # (must include service_type, service_instance, external_id).
  class Observation
    VALID_EVENT_TYPES = %w[snapshot_seen source_changed deleted].freeze
    RECORD_KIND = "observation"

    attr_reader :idempotency_key, :event_type, :observed_at, :item_key, :source,
                :published_at, :change, :source_created_at, :source_updated_at,
                :completed_at, :provenance, :last_known, :is_deleted

    def initialize(
      idempotency_key:,
      event_type:,
      observed_at:,
      item_key:,
      source:,
      published_at: nil,
      change: nil,
      source_created_at: nil,
      source_updated_at: nil,
      completed_at: nil,
      provenance: nil,
      last_known: nil,
      is_deleted: nil
    )
      @idempotency_key = idempotency_key
      @event_type = event_type
      @observed_at = observed_at
      @item_key = item_key
      @source = source
      @published_at = published_at
      @change = change
      @source_created_at = source_created_at
      @source_updated_at = source_updated_at
      @completed_at = completed_at
      @provenance = provenance
      @last_known = last_known
      @is_deleted = is_deleted

      validate!
    end

    def to_payload
      {
        contract_version: CONTRACT_VERSION,
        idempotency_key:,
        event_type:,
        observed_at: Timestamp.format(observed_at),
        published_at: Timestamp.format(published_at),
        item_key:,
        source:,
        change:,
        source_created_at: Timestamp.format(source_created_at),
        source_updated_at: Timestamp.format(source_updated_at),
        completed_at: Timestamp.format(completed_at),
        provenance:,
        last_known:,
        is_deleted:
      }.compact
    end

    private

    def validate!
      validate_text_encoding!
      raise ArgumentError, "idempotency_key is required" if idempotency_key.blank?
      raise ArgumentError, "idempotency_key must be a string" unless idempotency_key.is_a?(String)
      raise ArgumentError, "event_type must be one of: #{VALID_EVENT_TYPES.join(', ')}" unless VALID_EVENT_TYPES.include?(event_type)
      raise ArgumentError, "observed_at is required" if observed_at.blank?
      raise ArgumentError, "item_key is required" if item_key.blank?
      raise ArgumentError, "item_key must be a string" unless item_key.is_a?(String)

      validate_source!(source)
      validate_change!(change)
      validate_last_known!(last_known)
      validate_is_deleted!(is_deleted)
      validate_provenance!(provenance)
      Timestamp.validate!(observed_at, published_at, source_created_at, source_updated_at, completed_at)
    end

    # Provider text can carry malformed bytes; invalid UTF-8 must fail at
    # this boundary instead of crashing JSON generation deep in the publisher.
    # Runs before the other checks because present?/blank? themselves raise
    # on invalid byte sequences. Non-string values are left to the type
    # checks that follow.
    def validate_text_encoding!
      fields = { idempotency_key:, item_key:, observed_at:, published_at:,
                 source_created_at:, source_updated_at:, completed_at: }
      fields[:"change.field"] = change[:field] if change.is_a?(Hash)
      source.each { |key, value| fields[:"source.#{key}"] = value } if source.is_a?(Hash)
      Utf8.validate_fields!(fields)
    end

    def validate_source!(source)
      raise ArgumentError, "source is required" if source.nil?
      raise ArgumentError, "source must be a hash" unless source.is_a?(Hash)

      missing = %i[service_type service_instance external_id].reject { |k| source[k].present? }
      raise ArgumentError, "source is missing required fields: #{missing.join(', ')}" if missing.any?

      non_strings = %i[service_type service_instance external_id].reject { |k| source[k].is_a?(String) }
      raise ArgumentError, "source required fields must be strings: #{non_strings.join(', ')}" if non_strings.any?

      validate_source_url!(source[:source_url])
      validate_source_collection_keys!(source[:source_collection_keys])
    end

    # source_url and source_collection_keys are optional because some providers
    # cannot supply them, but the contract shapes them (URL string, collection
    # key list of {kind, id} objects), so a wrong type must fail here rather
    # than as a remote non-retryable row rejection.
    def validate_source_url!(url)
      return if url.nil? || url.is_a?(String)

      raise ArgumentError, "source.source_url must be a string when provided"
    end

    def validate_source_collection_keys!(keys)
      return if keys.nil? || (keys.is_a?(Array) && keys.all?(Hash))

      raise ArgumentError, "source.source_collection_keys must be an array of objects when provided"
    end

    # change describes a single field transition as field, from, and to. All
    # three keys must be present; from/to values may be nil when a field is
    # first observed or cleared, but a partial transition must not be published.
    def validate_change!(change)
      return if change.nil?
      return if valid_change?(change)

      raise ArgumentError, "change must be a hash with a non-blank :field and :from/:to keys when provided"
    end

    def valid_change?(change)
      change.is_a?(Hash) && change[:field].present? && change.key?(:from) && change.key?(:to)
    end

    # last_known preserves the pre-deletion state on tombstones as a structured
    # object, so a non-hash value must be rejected at the boundary.
    def validate_last_known!(value)
      return if value.nil? || value.is_a?(Hash)

      raise ArgumentError, "last_known must be a hash when provided"
    end

    def validate_is_deleted!(flag)
      return if flag.nil? || [true, false].include?(flag)

      raise ArgumentError, "is_deleted must be true or false when provided"
    end

    # provenance is the structured evidence for the observation; a non-hash
    # value must be rejected at the boundary like the other embedded objects.
    def validate_provenance!(value)
      return if value.nil? || value.is_a?(Hash)

      raise ArgumentError, "provenance must be a hash when provided"
    end
  end
end
