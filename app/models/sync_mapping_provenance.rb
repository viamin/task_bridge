# frozen_string_literal: true

module SyncMappingProvenance
  # Ranked weakest to strongest: a title match beats having no evidence
  # linking the pair at all, a sync-id match beats both, and an explicit
  # sync-created mapping (Base::Service#created_by_sync_provenance) is the
  # strongest evidence since the pair was linked at creation time rather
  # than inferred after the fact.
  METHOD_PRIORITY = %w[manual_backfill title_fallback source_sync_id created_by_sync].freeze

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

  # Unknown/typo'd methods rank below every known method (instead of above
  # all of them) so they can never outrank real evidence like source_sync_id
  # and can never permanently block it from being upgraded later.
  def method_priority(method)
    METHOD_PRIORITY.index(method) || -1
  end
end
