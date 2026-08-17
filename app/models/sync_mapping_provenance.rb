# frozen_string_literal: true

module SyncMappingProvenance
  module_function

  def preferred_for(items)
    collection_items = items.compact
    raise ArgumentError, "expected at least two items" if collection_items.length < 2

    left_item, right_item = preferred_pair_for(collection_items)
    left_item.mapping_provenance_with(right_item)
  end

  def preferred_pair_for(items)
    source_sync_id_match = items.combination(2).find do |left_item, right_item|
      left_item.mapping_provenance_with(right_item)[:method] == "source_sync_id"
    end

    source_sync_id_match || items.first(2)
  end
end
