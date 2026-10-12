# frozen_string_literal: true

module SyncBackfill
  class SourceProvenance
    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @counts = {
        items: Hash.new(0), mappings: Hash.new(0), skipped: Hash.new(0)
      }
    end

    def run!
      backfill_sync_items
      backfill_sync_collections
      summary
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
        backfill_collection(collection)
      end
    end

    def backfill_item(item)
      if item.external_id.blank?
        counts[:skipped]["missing_external_id"] += 1
        return
      end

      observed_at = item.last_observed_at || item.updated_at || item.created_at || Time.current
      prepare_item(item, observed_at)
      identity = Outbox::SourceIdentity.for(item)
      counts[:items][identity[:service_type]] += 1
      return if dry_run

      persist_prepared_item(item, observed_at)
      emit_baseline_snapshot(item, identity, observed_at)
      item.update_column(:last_snapshot, published_snapshot(item)) if item.last_snapshot.blank?
    end

    def prepare_item(item, observed_at)
      item.source_service_name ||= Base::SyncItem.inferred_service_name_for(item)
      item.source_service_instance ||= Base::Service.instance_name_for(item.source_service_name) || "default"
      item.source_service_type ||= item.provider
      item.source_external_id ||= item.external_id
      item.source_url ||= item.url
      item.source_updated_at ||= item.last_modified
      item.first_observed_at ||= observed_at
    end

    def persist_prepared_item(item, observed_at)
      attributes = item.changes.slice(
        "source_service_name", "source_service_instance", "source_service_type",
        "source_external_id", "source_url", "source_updated_at", "first_observed_at"
      ).transform_values(&:last)
      attributes["last_observed_at"] = observed_at if item.last_observed_at.blank?
      item.update_columns(attributes) if attributes.present?
    end

    def emit_baseline_snapshot(item, identity, observed_at)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: baseline_payload(item, identity, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def baseline_payload(item, identity, observed_at)
      published_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        source: identity,
        provenance: { detected_by: "backfill", backfilled_at: iso_timestamp(Time.current) }
      )
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end

    def backfill_collection(collection)
      observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
      provenance = collection.mapping_method.present? ? existing_provenance(collection) : inferred_provenance_for(collection)
      counts[:mappings][provenance.fetch(:confidence)] += collection.sync_items.size
      return if dry_run

      collection.update_mapping_provenance!(**provenance, observed_at:) if collection.mapping_method.blank?
      emit_mappings(collection, observed_at) unless collection.mapping_confidence == "low"
    end

    def existing_provenance(collection)
      {
        method: collection.mapping_method,
        confidence: collection.mapping_confidence || "low",
        metadata: collection.mapping_metadata || {}
      }
    end

    def emit_mappings(collection, observed_at)
      Outbox::MappingEmitter.emit_for_members(collection, members: collection.sync_items, observed_at:)
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

    def summary
      {
        dry_run:,
        items_by_service: counts[:items].sort.to_h,
        mappings_by_confidence: counts[:mappings].sort.to_h,
        skipped: counts[:skipped].sort.to_h
      }
    end

    attr_reader :counts, :dry_run
  end
end
