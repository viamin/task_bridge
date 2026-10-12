# frozen_string_literal: true

module SyncBackfill
  class SourceProvenance
    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = Hash.new(0)
    end

    def run!
      backfill_sync_items
      backfill_sync_collections
      backfill_item_snapshots
      backfill_mappings
      print_summary
      summary
    end

    private

    def backfill_sync_items
      # Base::SyncItem.inferred_service_name_for reads peer notes via
      # peer_sync_id_keys_for, which plucks a fresh notes column per item
      # rather than using a loaded association, so preloading sync_items
      # here would not save any queries.
      Base::SyncItem.find_each do |item|
        next skip_item(item, :incomplete) if item.external_id.blank?

        observed_at = observed_at_for(item)
        assign_source_provenance(item, observed_at)
        increment(:items_backfilled, item)
      end
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        backfill_collection_provenance(collection)
      end
    end

    def backfill_collection_provenance(collection)
      return if collection.mapping_method.present?

      observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
      provenance = inferred_provenance_for(collection)
      collection.update_mapping_provenance!(**provenance, observed_at:) unless dry_run?
      increment(:collections_backfilled, confidence: provenance.fetch(:confidence))
    end

    def backfill_item_snapshots
      Base::SyncItem.find_each do |item|
        next skip_item(item, :incomplete) if item.external_id.blank?

        observed_at = observed_at_for(item)
        enqueue_snapshot(item, observed_at) unless dry_run?
        increment(:snapshots, item)
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = mapping_confidence_for(collection)
        collection.sync_items.each do |item|
          next skip_item(item, :incomplete) if item.external_id.blank?
          next increment(:mappings_withheld, confidence:) if confidence == "low"

          Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: mapping_observed_at(collection)) unless dry_run?
          increment(:mappings, item, confidence:)
        end
      end
    end

    def assign_source_provenance(item, observed_at)
      return if provenance_complete?(item)

      item.source_service_name ||= Base::SyncItem.inferred_service_name_for(item)
      item.source_service_instance ||= Base::Service.instance_name_for(item.source_service_name) || "default"
      item.source_service_type ||= item.provider
      item.source_external_id ||= item.external_id
      item.source_url ||= item.url
      item.source_updated_at ||= item.last_modified
      item.first_observed_at ||= observed_at
      item.last_observed_at ||= observed_at
      item.source_metadata ||= {}
      item.save! unless dry_run?
    end

    def provenance_complete?(item)
      item.source_service_name.present? && item.source_service_instance.present? &&
        item.source_service_type.present? && item.source_external_id.present? &&
        item.first_observed_at.present? && item.last_observed_at.present?
    end

    def enqueue_snapshot(item, observed_at)
      identity = Outbox::SourceIdentity.for(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: snapshot_payload(item, identity, observed_at),
        service_type: identity.fetch(:service_type),
        service_instance: identity.fetch(:service_instance),
        external_id: identity.fetch(:external_id),
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def snapshot_payload(item, identity, observed_at)
      item.normalized_snapshot.deep_transform_values { |value| timestamp(value) }.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        source: identity,
        provenance: { detected_by: "backfill", baseline: true, backfilled_at: timestamp(observed_at) }
      )
    end

    def observed_at_for(item)
      item.last_observed_at || item.first_observed_at || item.updated_at || item.created_at || Time.current
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.mapping_established_at || collection.updated_at || collection.created_at || Time.current
    end

    def mapping_confidence_for(collection)
      return collection.mapping_confidence if collection.mapping_confidence.present?

      inferred_provenance_for(collection).fetch(:confidence)
    end

    def timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end

    def skip_item(item, reason)
      increment(:skipped, item, reason:)
    end

    def increment(metric, item = nil, confidence: nil, reason: nil)
      @summary[metric] += 1
      @summary[[metric, "service", service_for(item)]] += 1 if item
      @summary[[metric, "confidence", confidence]] += 1 if confidence
      @summary[[metric, "reason", reason]] += 1 if reason
    end

    def service_for(item)
      Base::Service.service_identifier_for(item.provider)
    end

    def print_summary
      output.puts "TaskBridge sync backfill#{' dry run' if dry_run?}: #{summary.slice(:items_backfilled, :collections_backfilled, :snapshots, :mappings, :mappings_withheld, :skipped)}"
      summary.select { |key, _| key.is_a?(Array) }.sort_by(&:first).each do |(metric, dimension, value), count|
        output.puts "#{metric} #{dimension}=#{value}: #{count}"
      end
    end

    attr_reader :summary, :output

    def dry_run?
      @dry_run
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
