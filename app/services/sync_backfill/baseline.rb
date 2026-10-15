# frozen_string_literal: true

module SyncBackfill
  class Baseline
    ELIGIBLE_MAPPING_CONFIDENCES = %w[high medium].freeze

    def self.run!(backfilled_at: Time.current)
      new(backfilled_at:).run!
    end

    def initialize(backfilled_at:)
      @backfilled_at = backfilled_at
    end

    def run!
      backfill_items
      backfill_mappings
    end

    private

    attr_reader :backfilled_at

    def backfill_items
      Base::SyncItem.find_each do |item|
        next if item.external_id.blank?

        enqueue_item(item)
      end
    end

    def enqueue_item(item)
      observed_at = item.first_observed_at || item.last_observed_at || backfilled_at
      identity = baseline_identity(item)
      snapshot = serialized_snapshot(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(snapshot, identity, observed_at),
        service_type: identity.fetch(:service_type),
        service_instance: identity.fetch(:service_instance),
        external_id: identity.fetch(:external_id),
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
      seed_snapshot_baseline(item, snapshot)
    end

    def item_payload(snapshot, identity, observed_at)
      snapshot.merge(
        source: identity,
        observed_at: timestamp(observed_at),
        provenance: {
          detected_by: "backfill",
          backfilled_at: timestamp(backfilled_at)
        }
      )
    end

    def baseline_identity(item)
      identity = Outbox::SourceIdentity.for(item)
      return identity unless identity.fetch(:service_instance) == identity.fetch(:service_type)

      identity.merge(service_instance: "#{identity.fetch(:service_type)}:default")
    end

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? timestamp(value) : value
      end
    end

    def seed_snapshot_baseline(item, snapshot)
      item.update_column(:last_snapshot, snapshot) if item.last_snapshot.blank?
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        next unless eligible_mapping?(collection)

        Outbox::MappingEmitter.emit_for_members(
          collection,
          members: collection.sync_items,
          observed_at: collection.mapping_established_at || collection.created_at || backfilled_at
        )
      end
    end

    def eligible_mapping?(collection)
      ELIGIBLE_MAPPING_CONFIDENCES.include?(collection.mapping_confidence)
    end

    def timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
