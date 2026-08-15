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
    VALID_MEMBERSHIP_ROLES = %w[canonical member].freeze
    RECORD_KIND = "mapping"

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
      @idempotency_key = idempotency_key
      @mapping_type = mapping_type
      @observed_at = observed_at
      @sync_collection = sync_collection
      @member = member
      @membership_role = membership_role
      @mapping_confidence = mapping_confidence
      @mapping_source = mapping_source
      @provenance = provenance

      validate!
    end

    def to_payload
      {
        contract_version: 1,
        idempotency_key:,
        mapping_type:,
        observed_at: Timestamp.format(observed_at),
        sync_collection:,
        member:,
        membership_role:,
        mapping_confidence:,
        mapping_source:,
        provenance:
      }.compact
    end

    private

    def validate!
      raise ArgumentError, "idempotency_key is required" if idempotency_key.blank?
      raise ArgumentError, "mapping_type must be one of: #{VALID_MAPPING_TYPES.join(', ')}" unless VALID_MAPPING_TYPES.include?(mapping_type)
      raise ArgumentError, "observed_at is required" if observed_at.blank?

      validate_sync_collection!(sync_collection)
      validate_member!(member)
      validate_enum!(membership_role, VALID_MEMBERSHIP_ROLES, :membership_role)
      validate_enum!(mapping_confidence, VALID_CONFIDENCE_LEVELS, :mapping_confidence)
      Timestamp.validate!(observed_at)
    end

    def validate_sync_collection!(sync_collection)
      raise ArgumentError, "sync_collection is required" if sync_collection.nil?
      raise ArgumentError, "sync_collection must be a hash" unless sync_collection.is_a?(Hash)
      raise ArgumentError, "sync_collection.sync_collection_id is required" if sync_collection[:sync_collection_id].blank?
    end

    def validate_member!(member)
      raise ArgumentError, "member is required" if member.nil?
      raise ArgumentError, "member must be a hash" unless member.is_a?(Hash)

      missing = %i[item_key service_type service_instance external_id].reject { |k| member[k].present? }
      raise ArgumentError, "member is missing required fields: #{missing.join(', ')}" if missing.any?
    end

    def validate_enum!(value, allowed, field)
      return if value.nil? || allowed.include?(value)

      raise ArgumentError, "#{field} must be one of: #{allowed.join(', ')}"
    end
  end
end
