# frozen_string_literal: true

module SyncBackfill
  class SourceProvenance
    def self.run!
      new.run!
    end

    def self.provenance_for(collection)
      new.provenance_for(collection)
    end

    def run!
      backfill_sync_items
      backfill_sync_collections
    end

    # Kept public so the outbox dry-run can show the same confidence and
    # method a real backfill would write, without mutating local records.
    def provenance_for(collection)
      items = collection.sync_items.to_a.compact
      default_metadata = { "sync_item_ids" => items.filter_map(&:id) }
      return { method: "manual_backfill", confidence: "low", metadata: default_metadata } if items.length < 2

      provenance = preferred_provenance(items)
      provenance.merge(metadata: default_metadata.merge(provenance.fetch(:metadata)))
    end

    private

    def backfill_sync_items
      # Base::SyncItem.inferred_service_name_for reads peer notes via
      # peer_sync_id_keys_for, which plucks a fresh notes column per item
      # rather than using a loaded association, so preloading sync_items
      # here would not save any queries.
      Base::SyncItem.find_each do |item|
        next if item.external_id.blank? || source_provenance_complete?(item)

        observed_at = item.updated_at || item.created_at || Time.current
        item.source_service_name ||= Base::SyncItem.inferred_service_name_for(item)
        item.observe_source!(observed_at:)
      end
    end

    def source_provenance_complete?(item)
      item.last_observed_at.present? && item.first_observed_at.present? &&
        item.source_service_name.present? && item.source_service_instance.present? &&
        item.source_service_type.present? && item.source_external_id.present? &&
        !item.source_metadata.nil?
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        next if collection.mapping_method.present?

        observed_at = collection.updated_at || collection.created_at || Time.current
        provenance = provenance_for(collection)
        collection.update_mapping_provenance!(**provenance, observed_at:)
      end
    end

    def preferred_provenance(items)
      SyncMappingProvenance.preferred_for(items)
    end
  end
end
