# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state view from rows that existed before
  # the observation pipeline. These are deliberately snapshots, not inferred
  # historical observations: their provenance says they were backfilled.
  class Outbox
    DETECTED_BY = "backfill"

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = Summary.new(dry_run:)
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary.to_h
    end

    private

    attr_reader :dry_run, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        item.external_id.present? ? enqueue_item(item) : summary.skip_item(item, "missing_external_id")
      end
    end

    def enqueue_item(item)
      identity = ::Outbox::SourceIdentity.for(item)
      observed_at = baseline_at(item)
      summary.item(identity[:service_type])
      return if dry_run

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

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        collection.sync_items.each { |item| backfill_mapping(collection, item) }
      end
    end

    def backfill_mapping(collection, item)
      return summary.skip_mapping(collection, "missing_external_id") if item.external_id.blank?

      confidence = collection.mapping_confidence.presence || "low"
      return summary.withhold_mapping(confidence) if confidence == "low"

      summary.mapping(confidence)
      return if dry_run

      ::Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: mapping_at(collection))
    end

    def item_payload(item, observed_at)
      item.normalized_snapshot.deep_transform_values { |value| iso_timestamp(value) }.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        provenance: { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(observed_at) }
      )
    end

    def baseline_at(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_at(collection)
      collection.mapping_established_at || collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def iso_timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end

    class Summary
      def initialize(dry_run:)
        @summary = {
          dry_run:,
          items_by_service: Hash.new(0),
          mappings_by_confidence: Hash.new(0),
          skipped: Hash.new(0)
        }
      end

      def item(service_type)
        @summary[:items_by_service][service_type] += 1
      end

      def mapping(confidence)
        @summary[:mappings_by_confidence][confidence] += 1
      end

      def withhold_mapping(confidence)
        @summary[:skipped]["withheld_#{confidence}_confidence_mapping"] += 1
      end

      def skip_item(_item, reason)
        @summary[:skipped]["item_#{reason}"] += 1
      end

      def skip_mapping(_collection, reason)
        @summary[:skipped]["mapping_#{reason}"] += 1
      end

      def to_h
        @summary.deep_transform_values { |value| value.is_a?(Hash) ? value.sort.to_h : value }
      end
    end
  end
end
