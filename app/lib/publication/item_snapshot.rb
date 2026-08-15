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

    TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%S.%6NZ"

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
      validate!(idempotency_key:, item_key:, observed_at:, title:, status:, source:)

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
    end

    def to_payload
      payload = {
        contract_version: 1,
        idempotency_key:,
        item_key:,
        entity_type: ENTITY_TYPE,
        observed_at: format_timestamp(observed_at),
        title:,
        status:,
        is_deleted:,
        completed_at: format_timestamp(completed_at),
        source_created_at: format_timestamp(source_created_at),
        source_updated_at: format_timestamp(source_updated_at),
        due_at: format_timestamp(due_at),
        started_at: format_timestamp(started_at),
        tags:,
        parent:,
        source:,
        sync_collection:,
        source_metadata:
      }
      payload[:notes_preview] = notes_preview if notes_preview
      payload.compact
    end

    private

    def validate!(idempotency_key:, item_key:, observed_at:, title:, status:, source:)
      raise ArgumentError, "idempotency_key is required" if idempotency_key.blank?
      raise ArgumentError, "item_key is required" if item_key.blank?
      raise ArgumentError, "observed_at is required" if observed_at.nil?
      raise ArgumentError, "title is required" if title.blank?
      raise ArgumentError, "status must be one of: #{VALID_STATUSES.join(', ')}" unless VALID_STATUSES.include?(status)

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
