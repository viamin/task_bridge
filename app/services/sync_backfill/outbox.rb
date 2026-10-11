# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from already synchronized
  # local records. This deliberately writes item snapshots, not observations:
  # a backfill establishes a baseline and is not historical change evidence.
  class Outbox
    CONFIDENCE = { "high" => "confirmed", "medium" => "inferred", "low" => "tentative" }.freeze

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
        item.external_id.present? ? enqueue_item(item) : skip_item(item)
      end
    end

    def enqueue_item(item)
      identity = ::Outbox::SourceIdentity.for(item)
      observed_at = item.first_observed_at || item.last_observed_at || item.created_at
      payload = snapshot_payload(item, observed_at)
      enqueue(record_kind: :item, payload:, context: { identity:, observed_at:, item: }) unless dry_run
      increment("items.#{dry_run ? 'would_enqueue' : 'enqueued'}.#{identity[:service_type]}")
    end

    def skip_item(item)
      service_type = ::Outbox::SourceIdentity.for(item).fetch(:service_type)
      increment("items.skipped.missing_external_id.#{service_type}")
    end

    def backfill_mappings
      SyncCollection.find_each do |collection|
        collection.sync_items.find_each { |item| enqueue_mapping(collection, item) }
      end
    end

    def enqueue_mapping(collection, item)
      confidence = CONFIDENCE.fetch(collection.mapping_confidence, "tentative")
      identity = ::Outbox::SourceIdentity.for(item)
      return increment("mappings.withheld.#{confidence}.#{identity[:service_type]}") if confidence == "tentative"
      return increment("mappings.skipped.missing_external_id.#{identity[:service_type]}") if item.external_id.blank?

      observed_at = collection.mapping_established_at || collection.mapping_last_observed_at || collection.created_at
      payload = mapping_payload(collection, item, identity, observed_at, confidence)
      enqueue(record_kind: :mapping, payload:, context: { identity:, observed_at:, item:, collection: }) unless dry_run
      increment("mappings.#{dry_run ? 'would_enqueue' : 'enqueued'}.#{confidence}.#{identity[:service_type]}")
    end

    def enqueue(record_kind:, payload:, context:)
      identity = context.fetch(:identity)
      item = context.fetch(:item)
      collection = context[:collection]
      OutboxEntry.enqueue(
        record_kind:,
        payload:,
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: collection&.id || item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: context.fetch(:observed_at)
      )
    end

    def snapshot_payload(item, observed_at)
      json_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        provenance: { detected_by: "backfill", backfilled_at: iso_timestamp(observed_at) }
      )
    end

    def mapping_payload(collection, item, identity, observed_at, confidence)
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        mapping_type: ::Outbox::MappingEmitter::MAPPING_TYPE,
        observed_at: iso_timestamp(observed_at),
        sync_collection: { sync_collection_id: collection.id, title: collection.title },
        member: identity.merge(item_key: item.item_key),
        membership_role: ::Outbox::MappingEmitter::MEMBERSHIP_ROLE,
        mapping_confidence: confidence,
        mapping_source: ::Outbox::MappingEmitter::SOURCE.fetch(collection.mapping_method, collection.mapping_method),
        provenance: {
          detected_by: "backfill",
          backfilled_at: iso_timestamp(observed_at),
          method: collection.mapping_method,
          confidence: collection.mapping_confidence,
          metadata: collection.mapping_metadata
        }
      }
    end

    def json_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def iso_timestamp(value)
      value.utc.iso8601(6)
    end

    def increment(key)
      summary[key] += 1
    end
  end
end
