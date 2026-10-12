# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state view without manufacturing historic
  # observations. It deliberately writes item snapshots only; the first live
  # source refresh is responsible for emitting an observation event.
  class OutboxBaseline
    CONFIDENCES_TO_PUBLISH = %w[high medium].freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = Hash.new(0)
    end

    def run!
      SourceProvenance.run!(dry_run:)
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :dry_run, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          count(:items_skipped_incomplete, item)
          next
        end

        count(:items, item)
        enqueue_item(item) unless dry_run
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        collection.sync_items.each do |item|
          if item.external_id.blank?
            count(:mappings_skipped_incomplete, item)
          elsif CONFIDENCES_TO_PUBLISH.include?(collection.mapping_confidence)
            count(:mappings, item, collection.mapping_confidence)
            emit_mapping(collection, item) unless dry_run
          else
            count(:mappings_withheld, item, collection.mapping_confidence || "unknown")
          end
        end
      end
    end

    def enqueue_item(item)
      identity = Outbox::SourceIdentity.for(item)
      observed_at = item.last_observed_at
      snapshot = serialized_snapshot(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, identity, observed_at, snapshot),
        service_type: identity[:service_type], service_instance: identity[:service_instance],
        external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified, observed_at:
      )
      item.update_column(:last_snapshot, snapshot) if item.last_snapshot.blank?
    end

    def emit_mapping(collection, item)
      Outbox::MappingEmitter.emit_for_members(
        collection, members: [item], observed_at: collection.mapping_last_observed_at || item.last_observed_at
      )
    end

    def item_payload(item, identity, observed_at, snapshot)
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at), item_key: item.item_key,
        source: identity, snapshot:,
        provenance: { detected_by: "backfill", baseline: true, backfilled_at: timestamp(observed_at) }
      }
    end

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? timestamp(value) : value }
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end

    def count(kind, item, confidence = nil)
      summary[kind] += 1
      summary[:services] = Hash.new { |hash, key| hash[key] = Hash.new(0) } unless summary[:services].is_a?(Hash)
      summary[:services][Outbox::SourceIdentity.for(item)[:service_type]][kind] += 1
      summary[:confidence] = Hash.new(0) unless summary[:confidence].is_a?(Hash)
      summary[:confidence][confidence] += 1 if confidence
    end
  end
end
