# frozen_string_literal: true

module SyncBackfill
  class SourceProvenance
    def self.run!
      new.run!
    end

    # The mapping confidence a backfill run will leave on `collection`:
    # complete provenance stays untouched, and a partial stored label survives
    # only while its method outranks what inference would record (mirroring
    # SyncCollection#update_mapping_provenance!'s override rule). The preview
    # reads this so its mapping counts match what Baseline will publish.
    def self.effective_mapping_confidence(collection)
      new.effective_mapping_confidence(collection)
    end

    def run!
      backfill_sync_items
      backfill_sync_collections
    end

    def effective_mapping_confidence(collection)
      return collection.mapping_confidence if mapping_provenance_complete?(collection)

      backfill_provenance_for(collection).fetch(:confidence)
    end

    private

    def stored_label_outranks?(collection, inferred)
      collection.mapping_method.present? &&
        SyncMappingProvenance.method_priority(collection.mapping_method) >
          SyncMappingProvenance.method_priority(inferred.fetch(:method))
    end

    def backfill_sync_items
      Base::SyncItem.in_batches do |relation|
        incomplete_items = relation.reject { |item| observation_and_provenance_complete?(item) }
        peer_notes = peer_notes_by_collection(incomplete_items)

        incomplete_items.each { |item| backfill_source_provenance(item, peer_notes[item.sync_collection_id]) }
      end
    end

    def backfill_source_provenance(item, peer_notes)
      observed_at = item.last_observed_at || item.first_observed_at || item.updated_at || item.created_at || Time.current
      item.source_service_name ||= Base::SyncItem.inferred_service_name_for(item, peer_notes:)
      item.observe_source!(observed_at:)
    end

    def peer_notes_by_collection(items)
      collection_ids = items.filter_map(&:sync_collection_id).uniq
      return {} if collection_ids.empty?

      Base::SyncItem.where(sync_collection_id: collection_ids)
                    .pluck(:id, :sync_collection_id, :notes)
                    .group_by { |_, collection_id, _| collection_id }
                    .transform_values { |entries| entries.map { |id, _, notes| [id, notes] } }
    end

    def observation_and_provenance_complete?(item)
      item.first_observed_at.present? &&
        item.last_observed_at.present? &&
        item.source_service_name.present? &&
        item.source_service_instance == Base::Service.instance_name_for(item.source_service_name) &&
        item.source_service_type.present? &&
        (item.external_id.blank? || item.source_external_id.present?) &&
        !item.source_metadata.nil?
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        next if mapping_provenance_complete?(collection)

        observed_at = collection.updated_at || collection.created_at || Time.current
        provenance = backfill_provenance_for(collection)
        collection.update_mapping_provenance!(**provenance, observed_at:)
      end
    end

    def backfill_provenance_for(collection)
      inferred = inferred_provenance_for(collection)
      return inferred unless stored_label_outranks?(collection, inferred)

      inferred.merge(
        method: collection.mapping_method,
        confidence: collection.mapping_confidence.presence || inferred.fetch(:confidence)
      )
    end

    def mapping_provenance_complete?(collection)
      collection.mapping_method.present? &&
        collection.mapping_confidence.present? &&
        !collection.mapping_metadata.nil? &&
        collection.mapping_established_at.present? &&
        collection.mapping_last_observed_at.present?
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
