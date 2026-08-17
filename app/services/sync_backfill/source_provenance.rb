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
      Base::SyncItem.find_each do |item|
        observed_at = item.updated_at || item.created_at || Time.current
        item.source_service_name ||= inferred_service_name_for(item)
        item.observe_source!(observed_at:)
      end
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        observed_at = collection.updated_at || collection.created_at || Time.current
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
      source_sync_id_match = items.combination(2).find do |left_item, right_item|
        left_item.mapping_provenance_with(right_item)[:method] == "source_sync_id"
      end
      left_item, right_item = source_sync_id_match || items.first(2)
      left_item.mapping_provenance_with(right_item)
    end

    def inferred_service_name_for(item)
      service_type = item.source_service_type.presence || item.provider
      base_identifier = Base::Service.service_identifier_for(service_type)
      matching_key = peer_sync_id_keys_for(item).find { |key| key.start_with?(base_identifier) }
      return service_type if matching_key.nil?

      instance_suffix = matching_key.delete_prefix(base_identifier).delete_suffix("_id").delete_prefix("_")
      [service_type, instance_suffix.presence].compact.join(":")
    end

    def peer_sync_id_keys_for(item)
      Array(item.sync_collection&.sync_items).flat_map do |peer_item|
        next [] if peer_item.id == item.id

        peer_item.notes.to_s.scan(/^([a-z0-9_]+_id):\s(.+)$/).filter_map do |key, value|
          key if value == item.external_id.to_s
        end
      end
    end
  end
end
