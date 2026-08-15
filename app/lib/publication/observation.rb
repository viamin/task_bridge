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
        contract_version: 1,
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
      raise ArgumentError, "idempotency_key is required" if idempotency_key.blank?
      raise ArgumentError, "event_type must be one of: #{VALID_EVENT_TYPES.join(', ')}" unless VALID_EVENT_TYPES.include?(event_type)
      raise ArgumentError, "observed_at is required" if observed_at.blank?
      raise ArgumentError, "item_key is required" if item_key.blank?

      validate_source!(source)
      validate_change!(change)
      validate_last_known!(last_known)
      validate_is_deleted!(is_deleted)
      validate_provenance!(provenance)
      Timestamp.validate!(observed_at, published_at, source_created_at, source_updated_at, completed_at)
    end

    def validate_source!(source)
      raise ArgumentError, "source is required" if source.nil?
      raise ArgumentError, "source must be a hash" unless source.is_a?(Hash)

      missing = %i[service_type service_instance external_id].reject { |k| source[k].present? }
      raise ArgumentError, "source is missing required fields: #{missing.join(', ')}" if missing.any?
    end

    # change describes a single field transition and must name the field it covers.
    def validate_change!(change)
      return if change.nil?
      return if change.is_a?(Hash) && change[:field].present?

      raise ArgumentError, "change must be a hash with a non-blank :field when provided"
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
