# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web with the current local state without creating
  # historical change events. Its deterministic timestamps make reruns safe.
  class OutboxBaseline
    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = Hash.new(0).merge(by_service: Hash.new(0))
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
        item.external_id.present? ? backfill_item(item) : count(:items_skipped_incomplete, item)
      end
    end

    def backfill_item(item)
      identity = Outbox::SourceIdentity.for(item)
      count(:items, item)
      return if dry_run

      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, identity),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: observed_at(item)
      )
    rescue ArgumentError
      count(:items_skipped_incomplete, item)
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        collection.sync_items.each { |item| backfill_mapping(collection, item) }
      end
    end

    def backfill_mapping(collection, item)
      confidence = collection.mapping_confidence.presence || "low"
      count(:"mappings_#{confidence}", item)
      return count(:mappings_withheld_low, item) if confidence == "low"
      return count(:mappings_skipped_incomplete, item) if item.external_id.blank?
      return if dry_run

      Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: mapping_observed_at(collection))
    end

    def item_payload(item, identity)
      snapshot = item.normalized_snapshot.deep_transform_values { |value| timestamp(value) }
      snapshot.except(:version).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at(item)),
        source: identity,
        provenance: { detected_by: "backfill", backfilled_at: timestamp(Time.current) }
      )
    end

    def observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end

    def count(key, item)
      summary[key] += 1
      summary[:by_service][Base::Service.service_identifier_for(item.provider)] += 1
    end
  end
end
