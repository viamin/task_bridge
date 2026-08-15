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
        contract_version: CONTRACT_VERSION,
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
      raise ArgumentError, "idempotency_key must be a string" unless idempotency_key.is_a?(String)
      raise ArgumentError, "item_key is required" if item_key.blank?
      raise ArgumentError, "item_key must be a string" unless item_key.is_a?(String)
      raise ArgumentError, "observed_at is required" if observed_at.blank?
      raise ArgumentError, "title is required" if title.blank?
      raise ArgumentError, "title must be a string" unless title.is_a?(String)
      raise ArgumentError, "status must be one of: #{VALID_STATUSES.join(', ')}" unless VALID_STATUSES.include?(status)
      raise ArgumentError, "is_deleted must be true or false" unless [true, false].include?(is_deleted)
      raise ArgumentError, "notes_preview must be a string when provided" unless notes_preview.nil? || notes_preview.is_a?(String)
      raise ArgumentError, "source_metadata must be a hash when provided" unless source_metadata.nil? || source_metadata.is_a?(Hash)

      validate_tags!
      validate_source!(source)
      validate_parent!(parent)
      validate_sync_collection!(sync_collection)
      Timestamp.validate!(observed_at, completed_at, source_created_at, source_updated_at, due_at, started_at)
    end

    # Tags are provider free text like title, so every entry must be a valid
    # UTF-8 string: a wrong-typed or malformed entry would otherwise surface
    # as a remote non-retryable row rejection, or crash JSON generation.
    def validate_tags!
      return if tags.nil? || (tags.is_a?(Array) && tags.all? { |tag| tag.is_a?(String) && tag.valid_encoding? })

      raise ArgumentError, "tags must be an array of valid UTF-8 strings when provided"
    end

    # Provider text can carry malformed bytes (for example from AppleScript
    # adapters); invalid UTF-8 must fail at this boundary instead of crashing
    # JSON generation deep in the publisher. Runs before the other checks
    # because present?/blank? themselves raise on invalid byte sequences.
    # Non-string values are left to the type checks that follow.
    def validate_text_encoding!
      fields = { idempotency_key:, item_key:, title:, notes_preview:,
                 observed_at:, completed_at:, source_created_at:, source_updated_at:,
                 due_at:, started_at: }
      source.each { |key, value| fields[:"source.#{key}"] = value } if source.is_a?(Hash)
      parent.each { |key, value| fields[:"parent.#{key}"] = value } if parent.is_a?(Hash)
      if sync_collection.is_a?(Hash)
        fields[:"sync_collection.sync_collection_id"] = sync_collection[:sync_collection_id]
        fields[:"sync_collection.title"] = sync_collection[:title]
      end
      Utf8.validate_fields!(fields)
    end

    # sync_collection embeds the same cross-system mapping fields that mapping
    # records carry, so the shared v1 enums apply here too: a snapshot must not
    # be publishable with values TaskBridge Web would reject row-by-row.
    def validate_sync_collection!(collection)
      return if collection.nil?
      raise ArgumentError, "sync_collection must be a hash when provided" unless collection.is_a?(Hash)
      raise ArgumentError, "sync_collection.sync_collection_id is required" if collection[:sync_collection_id].blank?

      validate_sync_collection_id!(collection[:sync_collection_id])

      title = collection[:title]
      raise ArgumentError, "sync_collection.title must be a string when provided" unless title.nil? || title.is_a?(String)

      validate_enum!(collection[:membership_role], Mapping::VALID_MEMBERSHIP_ROLES, "sync_collection.membership_role")
      validate_enum!(collection[:mapping_confidence], Mapping::VALID_CONFIDENCE_LEVELS, "sync_collection.mapping_confidence")

      mapping_source = collection[:mapping_source]
      return if mapping_source.nil? || mapping_source.is_a?(String)

      raise ArgumentError, "sync_collection.mapping_source must be a string when provided"
    end

    # sync_collection_id feeds the mapping idempotency key's collection scope
    # segment, so it follows the same string-or-numeric rule the key builder
    # enforces; any other type would surface as a remote non-retryable row
    # rejection instead of failing at this boundary.
    def validate_sync_collection_id!(id)
      return if id.is_a?(String) || id.is_a?(Numeric)

      raise ArgumentError, "sync_collection.sync_collection_id must be a string or numeric"
    end

    # parent references another item by the same identity-string fields used
    # everywhere else in the contract, so a wrong-typed value must fail here
    # rather than as a remote non-retryable row rejection. Both fields may be
    # nil when the source has no parent, per the v1 schema.
    def validate_parent!(parent)
      raise ArgumentError, "parent must be a hash when provided" unless parent.nil? || parent.is_a?(Hash)
      return if parent.nil?

      %i[external_id item_key].each do |field|
        next if parent[field].nil? || parent[field].is_a?(String)

        raise ArgumentError, "parent.#{field} must be a string when provided"
      end
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
      return if keys.nil? || (keys.is_a?(Array) && keys.all? { |key| valid_source_collection_key?(key) })

      raise ArgumentError, "source.source_collection_keys must be an array of objects with non-blank string kind and id when provided"
    end

    # Each entry identifies one provider collection as { kind:, id: }; an entry
    # missing either half, or carrying a wrong-typed or blank value, is not a
    # usable identifier. valid_encoding? precedes present? because present?
    # itself raises on invalid byte sequences.
    def valid_source_collection_key?(key)
      key.is_a?(Hash) && %i[kind id].all? do |field|
        value = key[field]
        value.is_a?(String) && value.valid_encoding? && value.present?
      end
    end
  end
end
