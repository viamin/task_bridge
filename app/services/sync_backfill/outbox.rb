# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from synchronized local
  # rows. These are deliberately snapshots, not historical observations.
  class Outbox
    PUBLISHED_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = Hash.new(0)
    end

    def run!
      SourceProvenance.run! unless dry_run?
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :summary

    def dry_run?
      @dry_run
    end

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary[:skipped_items] += 1
          next
        end

        summary["items:#{identity_for(item)[:service_type]}"] += 1
        enqueue_item(item) unless dry_run?
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        collection.sync_items.each { |item| backfill_mapping(collection, item) }
      end
    end

    def backfill_mapping(collection, item)
      confidence = collection.mapping_confidence.presence || "low"
      summary["mappings:#{confidence}"] += 1
      if item.external_id.blank?
        summary[:skipped_mappings] += 1
      elsif PUBLISHED_CONFIDENCES.exclude?(confidence)
        summary[:withheld_mappings] += 1
      elsif !dry_run?
        ::Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: mapping_observed_at(collection))
      end
    end

    def enqueue_item(item)
      identity = identity_for(item)
      ::OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, identity),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: item_observed_at(item)
      )
    end

    def item_payload(item, identity)
      snapshot = iso_values(item.normalized_snapshot)
      snapshot.merge(
        contract_version: ::OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(item_observed_at(item)),
        source: identity,
        provenance: {
          detected_by: "backfill",
          backfilled_at: iso_timestamp(item.first_observed_at || item_observed_at(item))
        }
      ).except(:version)
    end

    def identity_for(item)
      ::Outbox::SourceIdentity.for(item)
    end

    def item_observed_at(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_observed_at(collection)
      collection.mapping_established_at || collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def iso_values(value)
      value.deep_transform_values { |entry| entry.respond_to?(:utc) ? iso_timestamp(entry) : entry }
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
