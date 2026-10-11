# frozen_string_literal: true

module SyncBackfill
  class BaselineOutbox
    PUBLISHED_CONFIDENCES = %w[high medium].freeze

    def initialize(summary:, dry_run:, mapping_provenances:)
      @summary = summary
      @dry_run = dry_run
      @mapping_provenances = mapping_provenances
    end

    def run!
      Base::SyncItem.find_each { |item| enqueue_item(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| enqueue_mappings(collection) }
    end

    private

    attr_reader :dry_run, :mapping_provenances, :summary

    def enqueue_item(item)
      return summary.skip("missing_external_id") if item.external_id.blank?

      summary.record_item(item, skipped: false)
      return if dry_run

      identity = Outbox::SourceIdentity.for(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: payload_for(item, identity),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: observed_at_for(item)
      )
      item.update_column(:last_snapshot, published_snapshot_for(item)) if item.last_snapshot.blank?
    end

    def enqueue_mappings(collection)
      confidence = mapping_provenances.dig(collection.id, :confidence) || collection.mapping_confidence || "unknown"
      collection.sync_items.each { summary.record_mapping(collection, confidence) }
      return summary.skip("low_confidence_mapping") unless PUBLISHED_CONFIDENCES.include?(confidence)
      return if dry_run

      Outbox::MappingEmitter.emit_for_members(collection, members: collection.sync_items, observed_at: observed_at_for(collection))
    end

    def payload_for(item, identity)
      published_snapshot_for(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at_for(item)),
        source: identity,
        provenance: {
          detected_by: "backfill",
          baseline: true,
          backfilled_at: item.source_metadata.fetch(SourceProvenance::BACKFILLED_AT_KEY)
        }
      )
    end

    def published_snapshot_for(item)
      item.normalized_snapshot.deep_transform_values { |value| iso_timestamp(value) }
    end

    def observed_at_for(record)
      record.try(:first_observed_at) || record.try(:last_observed_at) || record.updated_at || record.created_at
    end

    def iso_timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end
  end
end
