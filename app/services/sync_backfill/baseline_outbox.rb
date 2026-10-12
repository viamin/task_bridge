# frozen_string_literal: true

module SyncBackfill
  # Seeds current-state outbox rows from data that existed before publication.
  # It deliberately emits item snapshots, not historical observations or
  # sync-run summaries: neither fact can be reconstructed reliably.
  # This coordinator exceeds the usual size target to keep its batch order
  # and the matching dry-run/real-run accounting in one auditable place.
  class BaselineOutbox
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, io: $stdout)
      new(dry_run:, io:).run!
    end

    def initialize(dry_run:, io:)
      @dry_run = dry_run
      @io = io
      @summary = Hash.new(0)
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      print_summary
      summary
    end

    private

    attr_reader :dry_run, :io, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary[:skipped_incomplete_items] += 1
          next
        end

        summary["items:#{service_type_for(item)}"] += 1
        enqueue_item(item) unless dry_run
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        provenance = mapping_provenance_for(collection)
        collection.sync_items.each { |item| backfill_mapping(collection, item, provenance) }
      end
    end

    def backfill_mapping(collection, item, provenance)
      if item.external_id.blank?
        summary[:skipped_incomplete_mappings] += 1
        return
      end

      confidence = provenance.fetch(:confidence)
      summary["mappings:#{service_type_for(item)}:#{confidence}"] += 1
      unless PUBLISHABLE_CONFIDENCES.include?(confidence)
        summary[:withheld_low_confidence_mappings] += 1
        return
      end

      apply_mapping_provenance(collection, provenance) unless dry_run || collection.mapping_method.present?
      Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: mapping_observed_at(collection)) unless dry_run
    end

    def enqueue_item(item)
      identity = Outbox::SourceIdentity.for(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: item_observed_at(item)
      )
    end

    def item_payload(item)
      item.normalized_snapshot.deep_transform_values { |value| timestamp(value) }.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        baseline: true,
        provenance: { detected_by: "backfill", backfilled_at: timestamp(Time.current) }
      )
    end

    def mapping_provenance_for(collection)
      return existing_provenance(collection) if collection.mapping_method.present?

      items = collection.sync_items.to_a
      return { method: "manual_backfill", confidence: "low", metadata: {} } if items.length < 2

      SyncMappingProvenance.preferred_for(items)
    end

    def existing_provenance(collection)
      { method: collection.mapping_method, confidence: collection.mapping_confidence, metadata: collection.mapping_metadata || {} }
    end

    def apply_mapping_provenance(collection, provenance)
      collection.update_mapping_provenance!(**provenance, observed_at: mapping_observed_at(collection))
    end

    def item_observed_at(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def service_type_for(item)
      Outbox::SourceIdentity.for(item).fetch(:service_type)
    end

    def timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end

    def print_summary
      io.puts("Baseline outbox#{' dry run' if dry_run}: #{summary.sort_by { |key, _| key.to_s }.to_h.to_json}")
    end
  end
end
