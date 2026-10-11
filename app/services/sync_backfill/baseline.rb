# frozen_string_literal: true

module SyncBackfill
  # Seeds the publication outbox from current local state, never reconstructed
  # historical changes.
  class Baseline
    PUBLISHED_MAPPING_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, backfilled_at: Time.current)
      new(dry_run:, backfilled_at:).run!
    end

    def initialize(dry_run:, backfilled_at:)
      @dry_run = dry_run
      @backfilled_at = backfilled_at
      @summary = { items: Hash.new(0), mappings: Hash.new(0), skipped: Hash.new(0) }
    end

    def run!
      SourceProvenance.run!(dry_run:)
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :backfilled_at, :dry_run, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          skip(:incomplete_item)
          next
        end

        identity = Outbox::SourceIdentity.for(item)
        if identity.values_at(:service_type, :service_instance, :external_id).any?(&:blank?)
          skip(:incomplete_item)
          next
        end

        summary[:items][identity[:service_type]] += 1
        enqueue_item(item, identity) unless dry_run?
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        collection.sync_items.each { |item| backfill_mapping(collection, item) }
      end
    end

    def backfill_mapping(collection, item)
      confidence = collection.mapping_confidence
      unless PUBLISHED_MAPPING_CONFIDENCES.include?(confidence)
        skip_mapping(confidence || "missing")
        return
      end
      if item.external_id.blank?
        skip(:incomplete_mapping_member)
        return
      end

      summary[:mappings][confidence] += 1
      return if dry_run?

      Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: mapping_observed_at_for(collection))
    end

    def enqueue_item(item, identity)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, identity),
        service_type: identity[:service_type], service_instance: identity[:service_instance],
        external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified, observed_at: observed_at_for(item)
      )
    end

    def item_payload(item, identity)
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        item_key: item.item_key,
        observed_at: timestamp(observed_at_for(item)), source: identity,
        snapshot: serialized_snapshot(item),
        provenance: { detected_by: "backfill", baseline: true, backfilled_at: timestamp(backfilled_at) }
      }
    end

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? timestamp(value) : value }
    end

    def observed_at_for(record)
      record.first_observed_at || record.last_observed_at || record.updated_at || record.created_at || backfilled_at
    end

    def mapping_observed_at_for(collection)
      collection.mapping_established_at || collection.mapping_last_observed_at || collection.updated_at ||
        collection.created_at || backfilled_at
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end

    def skip(reason)
      summary[:skipped][reason] += 1
    end

    def skip_mapping(confidence)
      summary[:skipped][:"mapping_#{confidence}"] += 1
    end

    def dry_run?
      @dry_run
    end
  end
end
