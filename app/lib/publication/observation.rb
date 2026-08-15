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

    TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%S.%6NZ"

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
      validate!(idempotency_key:, event_type:, observed_at:, item_key:, source:)

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
    end

    def to_payload
      {
        contract_version: 1,
        idempotency_key:,
        event_type:,
        observed_at: format_timestamp(observed_at),
        published_at: format_timestamp(published_at),
        item_key:,
        source:,
        change:,
        source_created_at: format_timestamp(source_created_at),
        source_updated_at: format_timestamp(source_updated_at),
        completed_at: format_timestamp(completed_at),
        provenance:,
        last_known:,
        is_deleted:
      }.compact
    end

    private

    def validate!(idempotency_key:, event_type:, observed_at:, item_key:, source:)
      raise ArgumentError, "idempotency_key is required" if idempotency_key.blank?
      raise ArgumentError, "event_type must be one of: #{VALID_EVENT_TYPES.join(', ')}" unless VALID_EVENT_TYPES.include?(event_type)
      raise ArgumentError, "observed_at is required" if observed_at.blank?
      raise ArgumentError, "item_key is required" if item_key.blank?

      validate_source!(source)
    end

    def validate_source!(source)
      raise ArgumentError, "source is required" if source.nil?

      missing = %i[service_type service_instance external_id].reject { |k| source[k].present? }
      raise ArgumentError, "source is missing required fields: #{missing.join(', ')}" if missing.any?
    end

    def format_timestamp(value)
      return nil if value.nil?
      return value if value.is_a?(String)

      value.utc.strftime(TIMESTAMP_FORMAT)
    end
  end
end
