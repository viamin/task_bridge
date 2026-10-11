# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web with current state without inventing historical
  # observations. The timestamp comes from the first local observation when
  # available, keeping a rerun's idempotency keys stable.
  class OutboxBaseline
    CONFIDENCE = { "high" => "confirmed", "medium" => "inferred" }.freeze

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
        if item.external_id.blank?
          count(:items_skipped_incomplete, item)
          next
        end

        enqueue_item(item) unless dry_run
        count(:items, item)
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = CONFIDENCE[collection.mapping_confidence]
        collection.sync_items.each do |item|
          if item.external_id.blank?
            count(:mappings_skipped_incomplete, item, confidence: collection.mapping_confidence)
          elsif confidence.nil?
            count(:mappings_withheld_low_confidence, item, confidence: collection.mapping_confidence || "unknown")
          else
            enqueue_mapping(collection, item, confidence) unless dry_run
            count(:mappings, item, confidence:)
          end
        end
      end
    end

    def enqueue_item(item)
      identity = Outbox::SourceIdentity.for(item)
      observed_at = observed_at_for(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def enqueue_mapping(collection, item, confidence)
      observed_at = collection.mapping_established_at || collection.created_at || observed_at_for(item)
      Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at:) if confidence.present?
    end

    def item_payload(item, observed_at)
      snapshot = serialized_snapshot(item, observed_at)
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        provenance: {
          detected_by: "backfill",
          backfilled_at: timestamp(observed_at),
          initial_observation: true
        }
      )
    end

    def serialized_snapshot(item, observed_at)
      item.normalized_snapshot.merge(observed_at:).deep_transform_values do |value|
        value.respond_to?(:utc) ? timestamp(value) : value
      end
    end

    def observed_at_for(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end

    def count(kind, item, confidence: nil)
      service = Outbox::SourceIdentity.for(item).fetch(:service_type)
      summary[[kind, service, confidence]] += 1
    end
  end
end
