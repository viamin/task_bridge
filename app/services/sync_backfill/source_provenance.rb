# frozen_string_literal: true

module SyncBackfill
  class SourceProvenance
    BACKFILL_DETECTED_BY = "backfill"

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = empty_summary
    end

    def run!
      backfill_sync_items
      backfill_sync_collections
      summary
    end

    private

    attr_reader :summary

    def backfill_sync_items
      # Base::SyncItem.inferred_service_name_for reads peer notes via
      # peer_sync_id_keys_for, which plucks a fresh notes column per item
      # rather than using a loaded association, so preloading sync_items
      # here would not save any queries.
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          increment(:items, :skipped_incomplete)
          next
        end

        observed_at = item.last_observed_at || item.updated_at || item.created_at || Time.current
        backfill_item_provenance(item, observed_at)
        snapshot = baseline_snapshot(item, observed_at)
        enqueue_item_snapshot(item, snapshot, observed_at)
        persist_snapshot(item, snapshot)
        increment(:items, :enqueued, service: Outbox::SourceIdentity.for(item)[:service_type])
      end
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
        provenance = collection_provenance(collection)
        backfill_collection_provenance(collection, provenance, observed_at)
        backfill_collection_memberships(collection, observed_at, provenance[:confidence])
      end
    end

    def backfill_item_provenance(item, observed_at)
      return if dry_run?

      item.source_service_name ||= Base::SyncItem.inferred_service_name_for(item)
      item.observe_source!(observed_at:)
    end

    def baseline_snapshot(item, observed_at)
      snapshot = item.normalized_snapshot.deep_transform_values { |value| iso_timestamp(value) }
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        provenance: { detected_by: BACKFILL_DETECTED_BY, backfilled_at: iso_timestamp(observed_at) }
      )
    end

    def enqueue_item_snapshot(item, snapshot, observed_at)
      return if dry_run?

      identity = Outbox::SourceIdentity.for(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: snapshot,
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def persist_snapshot(item, snapshot)
      return if dry_run? || item.last_snapshot == snapshot

      item.update_column(:last_snapshot, snapshot)
    end

    def collection_provenance(collection)
      if collection.mapping_method.present?
        return {
          method: collection.mapping_method,
          confidence: collection.mapping_confidence.presence || confidence_for(collection.mapping_method),
          metadata: collection.mapping_metadata || {}
        }
      end

      inferred_provenance_for(collection)
    end

    def backfill_collection_provenance(collection, provenance, observed_at)
      return if dry_run? || (collection.mapping_method.present? && collection.mapping_confidence.present?)

      collection.update_mapping_provenance!(**provenance, observed_at:)
    end

    def backfill_collection_memberships(collection, observed_at, confidence)
      return withhold_low_confidence(collection, confidence) if low_confidence?(confidence)

      collection.sync_items.each do |member|
        if member.external_id.blank?
          increment(:mappings, :skipped_incomplete)
          next
        end

        Outbox::MappingEmitter.emit_for_members(collection, members: [member], observed_at:) unless dry_run?
        increment(:mappings, :enqueued, confidence:)
      end
    end

    def withhold_low_confidence(collection, confidence)
      collection.sync_items.each { increment(:mappings, :withheld_low_confidence, confidence:) }
    end

    def low_confidence?(confidence)
      confidence == "low"
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

    def confidence_for(method)
      return "high" if %w[source_sync_id created_by_sync].include?(method)
      return "medium" if method == "title_fallback"

      "low"
    end

    def increment(section, key, service: nil, confidence: nil)
      summary[section][key] += 1
      summary[section][:by_service][service] += 1 if service
      summary[section][:by_confidence][confidence] += 1 if confidence
    end

    def empty_summary
      {
        dry_run: dry_run?,
        items: summary_section,
        mappings: summary_section,
        sync_runs: 0,
        observations: 0
      }
    end

    def summary_section
      { enqueued: 0, skipped_incomplete: 0, withheld_low_confidence: 0,
        by_service: Hash.new(0), by_confidence: Hash.new(0) }
    end

    def dry_run?
      @dry_run
    end

    def iso_timestamp(value)
      value.utc.iso8601(6) if value.respond_to?(:utc)
    end
  end
end
