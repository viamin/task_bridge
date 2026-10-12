# frozen_string_literal: true

module SyncBackfill
  class SourceProvenance
    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
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
        backfill_item(item)
      end
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        next if collection.mapping_method.present?

        observed_at = collection.updated_at || collection.created_at || Time.current
        provenance = inferred_provenance_for(collection)
        collection.update_mapping_provenance!(**provenance, observed_at:) unless @dry_run
      end
    end

    def backfill_item(item)
      observed_at = item.last_observed_at || item.updated_at || item.created_at || Time.current
      service_name = item.source_service_name.presence || Base::SyncItem.inferred_service_name_for(item)
      item.source_service_name ||= service_name
      item.source_service_instance ||= Base::Service.instance_name_for(service_name).presence || "default"
      item.source_service_type ||= item.provider
      item.source_external_id ||= item.external_id
      item.source_url ||= item.url
      item.source_updated_at ||= item.last_modified
      item.first_observed_at ||= observed_at
      item.last_observed_at ||= observed_at
      item.source_metadata ||= {}
      item.update_columns(item.changes.transform_values(&:last)) if item.changed? && !@dry_run
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
  end
end
