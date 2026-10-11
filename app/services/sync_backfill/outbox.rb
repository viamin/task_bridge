# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from already-synchronized
  # local records. These are deliberately item snapshots, rather than change
  # observations: they state only what was known when the backfill ran.
  class Outbox
    PUBLISHED_MAPPING_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = Hash.new(0)
      @services = Hash.new(0)
      @mapping_confidences = Hash.new(0)
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary.merge(services:, mapping_confidences:)
    end

    private

    attr_reader :dry_run, :summary, :services, :mapping_confidences

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary[:items_skipped_incomplete] += 1
          next
        end

        identity = ::Outbox::SourceIdentity.for(item)
        services[identity[:service_type]] += 1
        summary[dry_run ? :items_would_enqueue : :items_enqueued] += 1
        enqueue_item(item, identity) unless dry_run
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence.presence || inferred_confidence(collection)
        mapping_confidences[confidence] += collection.sync_items.size
        unless PUBLISHED_MAPPING_CONFIDENCES.include?(confidence)
          summary[:mappings_withheld_low_confidence] += collection.sync_items.size
          next
        end

        summary[dry_run ? :mappings_would_enqueue : :mappings_enqueued] += collection.sync_items.count(&:external_id?)
        next if dry_run

        ::Outbox::MappingEmitter.emit_for_members(
          collection, members: collection.sync_items, observed_at: observed_at(collection)
        )
      end
    end

    def enqueue_item(item, identity)
      timestamp = observed_at(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, identity, timestamp),
        service_type: identity[:service_type], service_instance: identity[:service_instance],
        external_id: identity[:external_id], source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: timestamp
      )
    end

    def item_payload(item, identity, timestamp)
      snapshot = item.normalized_snapshot.deep_transform_values { |value| iso_timestamp(value) }
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(timestamp), source: identity,
        provenance: { detected_by: "backfill", baseline: true, backfilled_at: iso_timestamp(timestamp) }
      )
    end

    def observed_at(record)
      record.try(:last_observed_at) || record.try(:mapping_last_observed_at) ||
        record.updated_at || record.created_at || Time.current
    end

    def inferred_confidence(collection)
      items = collection.sync_items.to_a
      return "low" if items.length < 2

      SyncMappingProvenance.preferred_for(items)[:confidence]
    end

    def iso_timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end
  end
end
