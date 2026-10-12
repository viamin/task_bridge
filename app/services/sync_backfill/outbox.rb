# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox from current local state. These are intentionally current
  # state snapshots, not reconstructed historical events.
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
      SourceProvenance.run! unless dry_run
      Base::SyncItem.find_each { |item| backfill_item(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_mappings(collection) }
      summary
    end

    private

    attr_reader :dry_run, :summary

    def backfill_item(item)
      return skipped_item(item, "missing_external_id") if item.external_id.blank?

      record(:items, item.service_name)
      return if dry_run

      ::OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item),
        **item_context(item)
      )
    end

    def backfill_mappings(collection)
      provenance = mapping_provenance(collection)
      collection.sync_items.each { |item| backfill_mapping(collection, item, provenance) }
    end

    def backfill_mapping(collection, item, provenance)
      return skipped_mapping(item.service_name, "missing_external_id") if item.external_id.blank?
      return skipped_mapping(item.service_name, "low_confidence") unless PUBLISHED_CONFIDENCES.include?(provenance[:confidence])

      record(:mappings, item.service_name, provenance[:confidence])
      return if dry_run

      ::Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: mapping_observed_at(collection))
    end

    def item_payload(item)
      snapshot = serialized_snapshot(item)
      identity = ::Outbox::SourceIdentity.for(item)
      {
        contract_version: ::OutboxEntry::PAYLOAD_VERSION,
        item_key: snapshot.fetch(:item_key),
        entity_type: "task",
        observed_at: timestamp(observed_at(item)),
        title: snapshot[:title],
        status: snapshot[:status],
        is_deleted: false,
        completed_at: timestamp(snapshot[:completed_at]),
        source_created_at: timestamp(snapshot[:source_created_at]),
        source_updated_at: timestamp(snapshot[:source_updated_at]),
        due_at: timestamp(snapshot[:due_at]),
        started_at: timestamp(snapshot[:start_at]),
        tags: snapshot[:tags],
        source: identity,
        provenance: { detected_by: "backfill", backfilled_at: timestamp(observed_at(item)) },
        source_metadata: snapshot[:metadata]
      }.compact
    end

    def item_context(item)
      identity = ::Outbox::SourceIdentity.for(item)
      {
        service_type: identity.fetch(:service_type),
        service_instance: identity.fetch(:service_instance),
        external_id: identity.fetch(:external_id),
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: observed_at(item)
      }
    end

    def mapping_provenance(collection)
      return { method: collection.mapping_method, confidence: collection.mapping_confidence } if collection.mapping_method.present?

      SourceProvenance.provenance_for(collection)
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
    end

    def observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at || Time.current
    end

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? timestamp(value) : value }
    end

    def timestamp(value)
      value&.utc&.iso8601(6)
    end

    def skipped_item(item, reason)
      record(:skipped_items, item.service_name, reason)
    end

    def skipped_mapping(service, reason)
      record(:skipped_mappings, service, reason)
    end

    def record(kind, service, detail = nil)
      summary[[kind, service, detail]] += 1
    end
  end
end
