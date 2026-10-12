# frozen_string_literal: true

module SyncBackfill
  class SourceProvenance
    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = {
        dry_run:,
        items: { enqueued: 0, existing: 0, skipped_incomplete: 0, by_service: Hash.new(0) },
        mappings: { enqueued: 0, existing: 0, withheld_low_confidence: 0,
                    skipped_incomplete: 0, by_confidence: Hash.new(0) }
      }
    end

    def run!
      backfill_sync_items
      backfill_sync_collections
      backfill_baseline_snapshots
      @summary
    end

    private

    def backfill_sync_items
      # Base::SyncItem.inferred_service_name_for reads peer notes via
      # peer_sync_id_keys_for, which plucks a fresh notes column per item
      # rather than using a loaded association, so preloading sync_items
      # here would not save any queries.
      Base::SyncItem.find_each do |item|
        observed_at = item.updated_at || item.created_at || Time.current
        next unless source_provenance_missing?(item)

        item.source_service_name ||= Base::SyncItem.inferred_service_name_for(item)
        item.observe_source!(observed_at:) unless @dry_run
      end
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        observed_at = collection.updated_at || collection.created_at || Time.current
        provenance = inferred_provenance_for(collection)
        next if collection.mapping_method.present?

        collection.update_mapping_provenance!(**provenance, observed_at:) unless @dry_run
      end
    end

    def backfill_baseline_snapshots
      Base::SyncItem.includes(:sync_collection).find_each { |item| backfill_baseline_for(item) }
    end

    def backfill_baseline_for(item)
      return skip_incomplete_item unless item.external_id.present?

      observed_at = item.last_observed_at || item.updated_at || item.created_at || Time.current
      identity = Outbox::SourceIdentity.for(item)
      tally(:items, :by_service, identity[:service_type])
      if @dry_run
        increment(:items, :enqueued)
        backfill_mapping_for(item, observed_at)
        return
      end

      row = OutboxEntry.enqueue(record_kind: :item, payload: item_payload(item, identity, observed_at),
                                service_type: identity[:service_type], service_instance: identity[:service_instance],
                                external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
                                source_updated_at: item.source_updated_at || item.last_modified, observed_at:)
      increment(:items, row.previously_new_record? ? :enqueued : :existing)
      item.update_column(:last_snapshot, published_snapshot(item)) if item.last_snapshot.blank?
      backfill_mapping_for(item, observed_at)
    end

    def backfill_mapping_for(item, observed_at)
      collection = item.sync_collection
      return unless collection

      confidence = collection.mapping_confidence || inferred_provenance_for(collection)[:confidence]
      tally(:mappings, :by_confidence, confidence)
      return increment(:mappings, :withheld_low_confidence) if confidence == "low"
      return if @dry_run && increment(:mappings, :enqueued)

      before = OutboxEntry.where(record_kind: "mapping", sync_collection_id: collection.id,
                                 external_id: item.external_id, observed_at:).exists?
      Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at:)
      increment(:mappings, before ? :existing : :enqueued)
    end

    def item_payload(item, identity, observed_at)
      published_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        source: identity,
        provenance: { detected_by: "backfill", backfilled_at: iso_timestamp(Time.current) }
      )
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? iso_timestamp(value) : value }
    end

    def source_provenance_missing?(item)
      item.source_service_name.blank? || item.source_service_instance.blank? || item.source_service_type.blank? ||
        item.source_external_id.blank? || item.last_observed_at.blank?
    end

    def skip_incomplete_item
      increment(:items, :skipped_incomplete)
      increment(:mappings, :skipped_incomplete)
    end

    def tally(section, tally_name, key)
      @summary.fetch(section).fetch(tally_name)[key] += 1
    end

    def increment(section, key)
      @summary.fetch(section)[key] += 1
      true
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
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
