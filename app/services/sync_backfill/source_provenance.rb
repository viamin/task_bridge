# frozen_string_literal: true

module SyncBackfill
  class SourceProvenance
    BACKFILLED_AT_KEY = "backfilled_at"

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = SyncBackfill::Summary.new
      @mapping_provenances = {}
    end

    def run!
      backfill_sync_items
      backfill_sync_collections
      SyncBackfill::BaselineOutbox.new(summary:, dry_run:, mapping_provenances:).run!
      summary.to_h
    end

    private

    def backfill_sync_items
      # Base::SyncItem.inferred_service_name_for reads peer notes via
      # peer_sync_id_keys_for, which plucks a fresh notes column per item
      # rather than using a loaded association, so preloading sync_items
      # here would not save any queries.
      Base::SyncItem.find_each do |item|
        observed_at = item.updated_at || item.created_at || Time.current
        attributes = source_attributes(item, observed_at)
        next if attributes.empty?

        item.update_columns(attributes) unless dry_run
      end
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        observed_at = collection.updated_at || collection.created_at || Time.current
        next if collection.mapping_method.present?

        provenance = inferred_provenance_for(collection)
        mapping_provenances[collection.id] = provenance
        collection.update_mapping_provenance!(**provenance, observed_at:) unless dry_run
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

    attr_reader :dry_run, :mapping_provenances, :summary

    def source_attributes(item, observed_at)
      service_name = Base::Service.normalized_service_name(
        item.source_service_name.presence || Base::SyncItem.inferred_service_name_for(item)
      )
      metadata = item.source_metadata.is_a?(Hash) ? item.source_metadata : {}
      backfilled_at = metadata[BACKFILLED_AT_KEY] || observed_at.utc.iso8601(6)
      attributes = {
        source_service_name: item.source_service_name || service_name,
        source_service_instance: item.source_service_instance || Base::Service.instance_name_for(service_name) || "default",
        source_service_type: item.source_service_type || item.provider,
        source_external_id: item.source_external_id || item.external_id,
        source_url: item.source_url || item.url,
        source_updated_at: item.source_updated_at || item.last_modified,
        first_observed_at: item.first_observed_at || observed_at,
        last_observed_at: item.last_observed_at || observed_at,
        source_metadata: metadata.merge(BACKFILLED_AT_KEY => backfilled_at)
      }.compact

      attributes.reject { |attribute, value| item.public_send(attribute) == value }
    end
  end
end
