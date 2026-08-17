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
      @source = ImmutableValue.copy(source)
      @published_at = published_at
      @change = ImmutableValue.copy(change)
      @source_created_at = source_created_at
      @source_updated_at = source_updated_at
      @completed_at = completed_at
      @provenance = ImmutableValue.copy(provenance)
      @last_known = ImmutableValue.copy(last_known)
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
      validate_deletion_fields!
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
      Utf8.validate_fields!(fields)
      Utf8.validate_structure!(:source, source) if source.is_a?(Hash)
      Utf8.validate_structure!(:change, change) if change.is_a?(Hash)
      Utf8.validate_structure!(:provenance, provenance) if provenance.is_a?(Hash)
      Utf8.validate_structure!(:last_known, last_known) if last_known.is_a?(Hash)
    end

    def validate_source!(source)
      raise ArgumentError, "source is required" if source.nil?
      raise ArgumentError, "source must be a hash" unless source.is_a?(Hash)

      missing = %i[service_type service_instance external_id].reject { |k| HashAccess.fetch(source, k).present? }
      raise ArgumentError, "source is missing required fields: #{missing.join(', ')}" if missing.any?

      non_strings = %i[service_type service_instance external_id].reject { |k| HashAccess.fetch(source, k).is_a?(String) }
      raise ArgumentError, "source required fields must be strings: #{non_strings.join(', ')}" if non_strings.any?

      validate_source_url!(HashAccess.fetch(source, :source_url))
      validate_source_collection_keys!(HashAccess.fetch(source, :source_collection_keys))
    end

    # source_url and source_collection_keys are optional because some providers
    # cannot supply them, but the contract shapes them (URL string, collection
    # key list of {kind, id} objects), so a wrong type must fail here rather
    # than as a remote non-retryable row rejection.
    def validate_source_url!(url)
      return if url.nil?
      return if url.is_a?(String) && url.present?

      raise ArgumentError, "source.source_url must be a non-blank string when provided"
    end

    def validate_source_collection_keys!(keys)
      return if keys.nil? || (keys.is_a?(Array) && keys.all? { |key| valid_source_collection_key?(key) })

      raise ArgumentError, "source.source_collection_keys must be an array of objects with non-blank string kind and id when provided"
    end

    # Each entry identifies one provider collection as { kind:, id: }; an entry
    # missing either half, or carrying a wrong-typed or blank value, is not a
    # usable identifier. valid_encoding? precedes present? because present?
    # itself raises on invalid byte sequences.
    def valid_source_collection_key?(key)
      key.is_a?(Hash) && %i[kind id].all? do |field|
        value = HashAccess.fetch(key, field)
        Utf8.serializable_string?(value) && value.present?
      end
    end

    # change describes a single field transition as field, from, and to. All
    # three keys must be present; from/to values may be nil when a field is
    # first observed or cleared, but a partial transition must not be published.
    # field names a contract field, so anything but a string would surface as a
    # remote non-retryable row rejection and must fail here instead.
    def validate_change!(change)
      return if change.nil?
      return if valid_change?(change)

      raise ArgumentError, "change must be a hash with a non-blank string :field and :from/:to keys when provided"
    end

    def valid_change?(change)
      return false unless change.is_a?(Hash)

      field = HashAccess.fetch(change, :field)

      field.is_a?(String) && field.present? &&
        HashAccess.key?(change, :from) && HashAccess.key?(change, :to)
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

    # last_known and is_deleted describe tombstones specifically. Allowing them
    # on snapshot_seen/source_changed would blur observation semantics, and
    # is_deleted: false is not a meaningful observation fact.
    def validate_deletion_fields!
      if event_type == "deleted"
        raise ArgumentError, "is_deleted must be true when provided for deleted observations" if is_deleted == false

        return
      end

      raise ArgumentError, "last_known is only valid for deleted observations" if last_known
      raise ArgumentError, "is_deleted is only valid for deleted observations" unless is_deleted.nil?
    end

    # provenance is the structured evidence for the observation; a non-hash
    # value must be rejected at the boundary like the other embedded objects.
    def validate_provenance!(value)
      return if value.nil? || value.is_a?(Hash)

      raise ArgumentError, "provenance must be a hash when provided"
    end
  end
end
