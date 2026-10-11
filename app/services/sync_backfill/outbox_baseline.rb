# frozen_string_literal: true

module SyncBackfill
  # Seeds the local publication outbox from already-synchronized records.
  # This is intentionally a current-state baseline, never historical change
  # detection: item rows carry explicit backfill provenance and no observation
  # rows are emitted.
  class OutboxBaseline
    BACKFILL_DETECTED_BY = "backfill"

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = Hash.new(0)
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :dry_run, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary[:items_skipped_incomplete] += 1
          next
        end

        identity = Outbox::SourceIdentity.for(item)
        summary[:"items_#{identity[:service_type]}"] += 1
        next if dry_run

        observed_at = observed_at_for(item)
        OutboxEntry.enqueue(record_kind: :item, payload: item_payload(item, identity, observed_at),
                            service_type: identity[:service_type], service_instance: identity[:service_instance],
                            external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
                            source_updated_at: item.source_updated_at || item.last_modified, observed_at:)
        item.update_column(:last_snapshot, published_snapshot(item))
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = mapping_confidence_for(collection)
        summary[:"mappings_#{confidence}"] += collection.sync_items.size
        if collection.mapping_confidence == "low"
          summary[:mappings_withheld_low_confidence] += collection.sync_items.size
          next
        end
        next if collection.mapping_confidence.blank?
        next if dry_run

        Outbox::MappingEmitter.emit_for_members(collection, members: collection.sync_items,
                                                            observed_at: mapping_observed_at_for(collection))
      end
    end

    def observed_at_for(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_observed_at_for(collection)
      collection.mapping_established_at || collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def mapping_confidence_for(collection)
      return collection.mapping_confidence if collection.mapping_confidence.present?

      items = collection.sync_items.to_a
      return "low" if items.length < 2

      SyncMappingProvenance.preferred_for(items).fetch(:confidence)
    end

    def item_payload(item, identity, observed_at)
      published_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        source: identity,
        provenance: {
          detected_by: BACKFILL_DETECTED_BY,
          baseline: true,
          backfilled_at: iso_timestamp(observed_at)
        }
      )
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
