# frozen_string_literal: true

module Publication
  # Represents a cross-system representation membership fact.
  #
  # Mappings are separate events so TaskBridge Web can track representation changes
  # without diffing snapshots. Successive facts about the same membership must use
  # distinct idempotency keys with different observed_at values.
  #
  # Required fields: idempotency_key, mapping_type, observed_at, sync_collection
  # (must include sync_collection_id), member (must include item_key, service_type,
  # service_instance, external_id).
  class Mapping
    VALID_MAPPING_TYPES = %w[representation_membership].freeze
    VALID_CONFIDENCE_LEVELS = %w[confirmed inferred tentative].freeze
    RECORD_KIND = "mapping"

    TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%S.%6NZ"

    attr_reader :idempotency_key, :mapping_type, :observed_at, :sync_collection,
                :member, :membership_role, :mapping_confidence, :mapping_source, :provenance

    def initialize(
      idempotency_key:,
      mapping_type:,
      observed_at:,
      sync_collection:,
      member:,
      membership_role: nil,
      mapping_confidence: nil,
      mapping_source: nil,
      provenance: nil
    )
      validate!(idempotency_key:, mapping_type:, observed_at:, sync_collection:, member:, mapping_confidence:)

      @idempotency_key = idempotency_key
      @mapping_type = mapping_type
      @observed_at = observed_at
      @sync_collection = sync_collection
      @member = member
      @membership_role = membership_role
      @mapping_confidence = mapping_confidence
      @mapping_source = mapping_source
      @provenance = provenance
    end

    def to_payload
      {
        contract_version: 1,
        idempotency_key:,
        mapping_type:,
        observed_at: format_timestamp(observed_at),
        sync_collection:,
        member:,
        membership_role:,
        mapping_confidence:,
        mapping_source:,
        provenance:
      }.compact
    end

    private

    def validate!(idempotency_key:, mapping_type:, observed_at:, sync_collection:, member:, mapping_confidence:)
      raise ArgumentError, "idempotency_key is required" if idempotency_key.blank?
      raise ArgumentError, "mapping_type must be one of: #{VALID_MAPPING_TYPES.join(', ')}" unless VALID_MAPPING_TYPES.include?(mapping_type)
      raise ArgumentError, "observed_at is required" if observed_at.nil?

      validate_sync_collection!(sync_collection)
      validate_member!(member)

      return unless mapping_confidence && !VALID_CONFIDENCE_LEVELS.include?(mapping_confidence)

      raise ArgumentError, "mapping_confidence must be one of: #{VALID_CONFIDENCE_LEVELS.join(', ')}"
    end

    def validate_sync_collection!(sync_collection)
      raise ArgumentError, "sync_collection is required" if sync_collection.nil?
      raise ArgumentError, "sync_collection.sync_collection_id is required" if sync_collection[:sync_collection_id].nil?
    end

    def validate_member!(member)
      raise ArgumentError, "member is required" if member.nil?

      missing = %i[item_key service_type service_instance external_id].reject { |k| member[k].present? }
      raise ArgumentError, "member is missing required fields: #{missing.join(', ')}" if missing.any?
    end

    def format_timestamp(value)
      return nil if value.nil?
      return value if value.is_a?(String)

      value.utc.strftime(TIMESTAMP_FORMAT)
    end
  end
end
