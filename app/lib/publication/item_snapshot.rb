# frozen_string_literal: true

module Publication
  # Represents the normalized current-state snapshot of a source item.
  #
  # Required fields: idempotency_key, item_key, observed_at, title, status,
  # is_deleted, and source (must include service_type, service_instance, external_id).
  #
  # notes_preview must be omitted unless the caller has confirmed the source is
  # allowlisted for note export per the security constraints in RDR 215.
  class ItemSnapshot
    VALID_STATUSES = %w[open completed dropped].freeze
    ENTITY_TYPE = "task"
    RECORD_KIND = "item"

    attr_reader :idempotency_key, :item_key, :observed_at, :title, :status,
                :is_deleted, :source, :completed_at, :source_created_at, :source_updated_at,
                :due_at, :started_at, :notes_preview, :tags, :parent,
                :sync_collection, :source_metadata

    def initialize(
      idempotency_key:,
      item_key:,
      observed_at:,
      title:,
      status:,
      is_deleted:,
      source:,
      completed_at: nil,
      source_created_at: nil,
      source_updated_at: nil,
      due_at: nil,
      started_at: nil,
      notes_preview: nil,
      tags: nil,
      parent: nil,
      sync_collection: nil,
      source_metadata: nil
    )
      @idempotency_key = idempotency_key
      @item_key = item_key
      @observed_at = observed_at
      @title = title
      @status = status
      @is_deleted = is_deleted
      @source = source
      @completed_at = completed_at
      @source_created_at = source_created_at
      @source_updated_at = source_updated_at
      @due_at = due_at
      @started_at = started_at
      @notes_preview = notes_preview
      @tags = tags
      @parent = parent
      @sync_collection = sync_collection
      @source_metadata = source_metadata

      validate!
    end

    def to_payload
      payload = {
        contract_version: 1,
        idempotency_key:,
        item_key:,
        entity_type: ENTITY_TYPE,
        observed_at: Timestamp.format(observed_at),
        title:,
        status:,
        is_deleted:,
        completed_at: Timestamp.format(completed_at),
        source_created_at: Timestamp.format(source_created_at),
        source_updated_at: Timestamp.format(source_updated_at),
        due_at: Timestamp.format(due_at),
        started_at: Timestamp.format(started_at),
        tags:,
        parent:,
        source:,
        sync_collection:,
        source_metadata:
      }
      # Included only when present: an allowlisted preview must never degrade
      # to an empty string in the payload.
      payload[:notes_preview] = notes_preview if notes_preview.present?
      payload.compact
    end

    private

    def validate!
      validate_text_encoding!
      raise ArgumentError, "idempotency_key is required" if idempotency_key.blank?
      raise ArgumentError, "item_key is required" if item_key.blank?
      raise ArgumentError, "observed_at is required" if observed_at.blank?
      raise ArgumentError, "title must be a string" unless title.is_a?(String)
      raise ArgumentError, "title is required" if title.blank?
      raise ArgumentError, "status must be one of: #{VALID_STATUSES.join(', ')}" unless VALID_STATUSES.include?(status)
      raise ArgumentError, "is_deleted must be true or false" unless [true, false].include?(is_deleted)
      raise ArgumentError, "tags must be an array when provided" unless tags.nil? || tags.is_a?(Array)
      raise ArgumentError, "notes_preview must be a string when provided" unless notes_preview.nil? || notes_preview.is_a?(String)
      raise ArgumentError, "parent must be a hash when provided" unless parent.nil? || parent.is_a?(Hash)
      raise ArgumentError, "source_metadata must be a hash when provided" unless source_metadata.nil? || source_metadata.is_a?(Hash)

      validate_source!(source)
      validate_sync_collection!(sync_collection)
      Timestamp.validate!(observed_at, completed_at, source_created_at, source_updated_at, due_at, started_at)
    end

    # Provider text can carry malformed bytes (for example from AppleScript
    # adapters); invalid UTF-8 must fail at this boundary instead of crashing
    # JSON generation deep in the publisher. Runs before the other checks
    # because present?/blank? themselves raise on invalid byte sequences.
    # Non-string values are left to the type checks that follow.
    def validate_text_encoding!
      fields = { title:, notes_preview: }
      invalid = fields.select { |_, value| value.is_a?(String) && !value.valid_encoding? }
      raise ArgumentError, "#{invalid.keys.join(', ')} must be valid UTF-8" if invalid.any?
    end

    # sync_collection embeds the same cross-system mapping fields that mapping
    # records carry, so the shared v1 enums apply here too: a snapshot must not
    # be publishable with values TaskBridge Web would reject row-by-row.
    def validate_sync_collection!(collection)
      return if collection.nil?
      raise ArgumentError, "sync_collection must be a hash when provided" unless collection.is_a?(Hash)
      raise ArgumentError, "sync_collection.sync_collection_id is required" if collection[:sync_collection_id].blank?

      validate_enum!(collection[:membership_role], Mapping::VALID_MEMBERSHIP_ROLES, "sync_collection.membership_role")
      validate_enum!(collection[:mapping_confidence], Mapping::VALID_CONFIDENCE_LEVELS, "sync_collection.mapping_confidence")
    end

    def validate_enum!(value, allowed, field)
      return if value.nil? || allowed.include?(value)

      raise ArgumentError, "#{field} must be one of: #{allowed.join(', ')}"
    end

    def validate_source!(source)
      raise ArgumentError, "source is required" if source.nil?
      raise ArgumentError, "source must be a hash" unless source.is_a?(Hash)

      missing = %i[service_type service_instance external_id].reject { |k| source[k].present? }
      raise ArgumentError, "source is missing required fields: #{missing.join(', ')}" if missing.any?
    end
  end
end
