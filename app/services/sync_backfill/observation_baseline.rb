# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from locally synchronized
  # records. These rows describe the first known state, never a past change.
  class ObservationBaseline
    def self.run!(dry_run: false, backfilled_at: Time.current)
      new(dry_run:, backfilled_at:).run!
    end

    def initialize(dry_run:, backfilled_at:)
      @dry_run = dry_run
      @backfilled_at = backfilled_at
      @summary = empty_summary
    end

    def run!
      Base::SyncItem.find_each { |item| backfill_item(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
      summary
    end

    private

    attr_reader :backfilled_at, :dry_run, :summary

    def backfill_item(item)
      return skip(:missing_external_id) if item.external_id.blank?

      observed_at = observation_time_for(item)
      identity = Outbox::SourceIdentity.for(item)
      increment_service(identity[:service_type], :items)
      enqueue_item(item, identity, observed_at) unless dry_run
      persist_snapshot(item) unless dry_run
    end

    def enqueue_item(item, identity, observed_at)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def item_payload(item, observed_at)
      serialized_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        provenance: { detected_by: "backfill", backfilled_at: timestamp(backfilled_at), baseline: true }
      )
    end

    def persist_snapshot(item)
      return if item.last_snapshot.present?

      item.update_column(:last_snapshot, serialized_snapshot(item))
    end

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? timestamp(value) : value }
    end

    def backfill_collection(collection)
      provenance = mapping_provenance_for(collection)
      increment_confidence(provenance[:confidence])
      return skip(:low_confidence_mapping) unless Outbox::MappingEmitter.publishable?(mapping_collection(collection, provenance))

      collection.sync_items.each { |item| backfill_membership(collection, item, provenance) }
    end

    def backfill_membership(collection, item, provenance)
      return skip(:missing_external_id) if item.external_id.blank?

      identity = Outbox::SourceIdentity.for(item)
      increment_service(identity[:service_type], :mappings)
      return if dry_run

      mapping = mapping_collection(collection, provenance)
      Outbox::MappingEmitter.emit_for_members(mapping, members: [item], observed_at: mapping_time_for(collection))
    end

    def mapping_collection(collection, provenance)
      return collection if collection.mapping_method.present?

      collection.dup.tap do |copy|
        copy.mapping_method = provenance[:method]
        copy.mapping_confidence = provenance[:confidence]
        copy.mapping_metadata = provenance[:metadata]
      end
    end

    def mapping_provenance_for(collection)
      return stored_mapping_provenance(collection) if collection.mapping_method.present?

      SourceProvenance.provenance_for(collection)
    end

    def stored_mapping_provenance(collection)
      {
        method: collection.mapping_method,
        confidence: collection.mapping_confidence,
        metadata: collection.mapping_metadata
      }
    end

    def observation_time_for(item)
      item.last_observed_at || item.updated_at || item.created_at || backfilled_at
    end

    def mapping_time_for(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || backfilled_at
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end

    def empty_summary
      { dry_run:, services: Hash.new { |hash, key| hash[key] = { items: 0, mappings: 0 } },
        confidence: Hash.new(0), skipped: Hash.new(0) }
    end

    def increment_service(service, kind)
      summary[:services][service][kind] += 1
    end

    def increment_confidence(confidence)
      summary[:confidence][confidence] += 1
    end

    def skip(reason)
      summary[:skipped][reason] += 1
    end
  end
end
