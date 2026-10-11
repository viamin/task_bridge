# frozen_string_literal: true

module SyncBackfill
  class SourceProvenance
    BACKFILL_DETECTED_BY = "backfill"
    PUBLISHABLE_MAPPING_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, output: nil)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = {
        dry_run:,
        items: { enqueued: 0, skipped_incomplete: 0, by_service: Hash.new(0) },
        mappings: { enqueued: 0, withheld_low_confidence: 0, skipped_incomplete: 0, by_confidence: Hash.new(0) }
      }
    end

    def run!
      backfill_sync_items
      backfill_sync_collections
      output&.puts(JSON.generate(summary))
      summary
    end

    private

    attr_reader :dry_run, :output, :summary

    def backfill_sync_items
      # Base::SyncItem.inferred_service_name_for reads peer notes via
      # peer_sync_id_keys_for, which plucks a fresh notes column per item
      # rather than using a loaded association, so preloading sync_items
      # here would not save any queries.
      Base::SyncItem.find_each do |item|
        backfill_item(item)
      end
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        backfill_collection(collection)
      end
    end

    def backfill_item(item)
      return skip_item unless item.external_id.present?

      observed_at = item.last_observed_at || item.updated_at || item.created_at || Time.current
      assign_item_provenance(item, observed_at)
      enqueue_item_snapshot(item, observed_at)
      summary[:items][:enqueued] += 1
      summary[:items][:by_service][Outbox::SourceIdentity.for(item)[:service_type]] += 1
    end

    def assign_item_provenance(item, observed_at)
      attributes = {
        source_service_name: item.source_service_name.presence || Base::SyncItem.inferred_service_name_for(item),
        source_external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url,
        source_updated_at: item.source_updated_at || item.last_modified,
        first_observed_at: item.first_observed_at || observed_at,
        last_observed_at: item.last_observed_at || observed_at,
        source_metadata: item.source_metadata || {}
      }
      attributes[:source_service_instance] = item.source_service_instance.presence ||
                                             Base::Service.instance_name_for(attributes[:source_service_name])
      attributes[:source_service_type] = item.source_service_type.presence || item.provider
      item.assign_attributes(attributes)
      item.observe_source!(observed_at:) unless dry_run
    end

    def enqueue_item_snapshot(item, observed_at)
      return if dry_run

      identity = Outbox::SourceIdentity.for(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_snapshot_payload(item, observed_at),
        **identity.slice(:service_type, :service_instance, :external_id),
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def item_snapshot_payload(item, observed_at)
      item.normalized_snapshot.deep_transform_values { |value| iso_timestamp(value) || value }.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        provenance: { detected_by: BACKFILL_DETECTED_BY, backfilled_at: iso_timestamp(observed_at) }
      )
    end

    def backfill_collection(collection)
      observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
      establish_mapping_provenance(collection, observed_at)
      confidence = collection.mapping_confidence
      summary[:mappings][:by_confidence][confidence || "unknown"] += collection.sync_items.length
      return withhold_low_confidence(collection) unless PUBLISHABLE_MAPPING_CONFIDENCES.include?(confidence)

      collection.sync_items.each { |item| enqueue_mapping(collection, item, observed_at) }
    end

    def establish_mapping_provenance(collection, observed_at)
      return if collection.mapping_method.present?

      provenance = inferred_provenance_for(collection)
      collection.update_mapping_provenance!(**provenance, observed_at:) unless dry_run
      return unless dry_run

      collection.assign_attributes(
        mapping_method: provenance[:method], mapping_confidence: provenance[:confidence],
        mapping_metadata: provenance[:metadata], mapping_established_at: collection.created_at || observed_at,
        mapping_last_observed_at: observed_at
      )
    end

    def enqueue_mapping(collection, item, observed_at)
      return skip_mapping if item.external_id.blank?
      return if dry_run

      Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at:)
      summary[:mappings][:enqueued] += 1
    end

    def withhold_low_confidence(collection)
      summary[:mappings][:withheld_low_confidence] += collection.sync_items.length
    end

    def skip_item
      summary[:items][:skipped_incomplete] += 1
    end

    def skip_mapping
      summary[:mappings][:skipped_incomplete] += 1
    end

    def iso_timestamp(value)
      value.utc.iso8601(6) if value.respond_to?(:utc)
    end

    def inferred_provenance_for(collection)
      items = collection.sync_items.to_a.compact
      default_metadata = { "sync_item_ids" => items.filter_map(&:id) }
      return { method: "manual_backfill", confidence: "low", metadata: default_metadata } if items.length < 2

      provenance = preferred_provenance(items)

      provenance.merge(metadata: default_metadata.merge(provenance.fetch(:metadata)))
    end

    def preferred_provenance(items)
      SyncMappingProvenance.preferred_for(items)
    end
  end
end
