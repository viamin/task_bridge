# frozen_string_literal: true

module SyncBackfill
  class SourceProvenance
    def self.run!
      new.run!
    end

    def run!
      backfill_sync_items
      backfill_sync_collections
    end

    private

    def backfill_sync_items
      # Base::SyncItem.inferred_service_name_for reads peer notes via
      # peer_sync_id_keys_for, which plucks a fresh notes column per item
      # rather than using a loaded association, so preloading sync_items
      # here would not save any queries.
      Base::SyncItem.find_each do |item|
        next unless source_provenance_incomplete?(item)

        observed_at = item.last_observed_at || item.last_modified || item.updated_at || item.created_at || Time.current
        item.source_service_name ||= Base::SyncItem.inferred_service_name_for(item)
        item.observe_source!(observed_at:)
      end
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        next unless mapping_provenance_incomplete?(collection)

        observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
        provenance = inferred_provenance_for(collection)
        collection.update_mapping_provenance!(**provenance, observed_at:)
      end
    end

    def inferred_provenance_for(collection)
      items = collection.sync_items.to_a.compact
      default_metadata = { "sync_item_ids" => items.filter_map(&:id) }
      return { method: "manual_backfill", confidence: "low", metadata: default_metadata } if items.length < 2

      provenance = preferred_provenance(items)

      provenance.merge(metadata: default_metadata.merge(provenance.fetch(:metadata)))
    end

    def preferred_provenance(items)
      SyncMappingProvenance.preferred_for(items)
    end

    def source_provenance_incomplete?(item)
      item.last_observed_at.blank? || item.source_service_name.blank? ||
        item.source_service_type.blank? || item.source_external_id.blank?
    end

    def mapping_provenance_incomplete?(collection)
      collection.mapping_method.blank? || collection.mapping_confidence.blank? ||
        collection.mapping_metadata.blank? || collection.mapping_established_at.blank? ||
        collection.mapping_last_observed_at.blank?
    end
  end
end
