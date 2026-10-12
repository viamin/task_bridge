# frozen_string_literal: true

module SyncBackfill
  # Seeds current state into the outbox without inventing historical events.
  class OutboxBaseline
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, backfilled_at: Time.current)
      new(dry_run:, backfilled_at:).run!
    end

    def initialize(dry_run:, backfilled_at:)
      @dry_run = dry_run
      @backfilled_at = backfilled_at
      @summary = Hash.new(0)
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :backfilled_at, :dry_run, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary[:skipped_incomplete_items] += 1
          next
        end

        summary[service_key(item)] += 1
        enqueue_item(item) unless dry_run
      end
    end

    def enqueue_item(item)
      identity = Outbox::SourceIdentity.for(item)
      observed_at = item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at
      payload = snapshot_payload(item, identity, observed_at)
      OutboxEntry.enqueue(record_kind: :item, payload:, service_type: identity[:service_type],
                          service_instance: identity[:service_instance], external_id: identity[:external_id],
                          sync_collection_id: item.sync_collection_id, source_updated_at: item.source_updated_at,
                          observed_at:)
    end

    def snapshot_payload(item, identity, observed_at)
      item.normalized_snapshot.deep_transform_values { |value| iso_timestamp(value) }
          .merge(observed_at: iso_timestamp(observed_at), source: identity,
                 provenance: { detected_by: "backfill", backfilled_at: iso_timestamp(backfilled_at) })
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = mapping_provenance_for(collection).fetch(:confidence).to_s
        unless PUBLISHABLE_CONFIDENCES.include?(confidence)
          summary["withheld_#{confidence.presence || 'unknown'}_mappings"] += collection.sync_items.size
          next
        end

        summary["#{confidence}_mappings"] += collection.sync_items.size
        next if dry_run

        Outbox::MappingEmitter.emit_for_members(
          collection, members: collection.sync_items, observed_at: mapping_observed_at(collection)
        )
      end
    end

    def mapping_observed_at(collection)
      collection.mapping_established_at || collection.created_at || backfilled_at
    end

    def mapping_provenance_for(collection)
      return { confidence: collection.mapping_confidence } if collection.mapping_method.present?

      items = collection.sync_items.to_a.compact
      return { confidence: "low" } if items.length < 2

      SyncMappingProvenance.preferred_for(items)
    end

    def service_key(item)
      "service_#{Outbox::SourceIdentity.for(item)[:service_type]}"
    end

    def iso_timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end
  end
end
