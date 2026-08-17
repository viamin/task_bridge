# frozen_string_literal: true

module SyncMappingProvenance
  # Ranked weakest to strongest: a title match beats having no evidence
  # linking the pair at all, and a sync-id match beats both.
  METHOD_PRIORITY = %w[manual_backfill title_fallback source_sync_id].freeze

  module_function

  def preferred_for(items)
    collection_items = items.compact
    raise ArgumentError, "expected at least two items" if collection_items.length < 2

    pair_provenances(collection_items).max_by { |provenance| method_priority(provenance[:method]) }
  end

  def pair_provenances(items)
    items.combination(2).map do |left_item, right_item|
      left_item.mapping_provenance_with(right_item)
    end
  end

  def method_priority(method)
    METHOD_PRIORITY.index(method) || METHOD_PRIORITY.length
  end
end
