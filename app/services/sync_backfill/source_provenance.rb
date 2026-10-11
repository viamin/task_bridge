# frozen_string_literal: true

module SyncBackfill
  class SourceProvenance
    BASELINE_DETECTED_BY = "backfill"

    def self.run!(dry_run: false, output: nil)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output || $stdout
      @summary = {
        items: Hash.new(0), mappings: Hash.new(0), skipped: Hash.new(0)
      }
    end

    def run!
      backfill_sync_items
      backfill_sync_collections
      emit_baseline_snapshots
      emit_mapping_observations
      output.puts(dry_run_output) if dry_run?
      summary
    end

    private

    attr_reader :output, :summary

    def backfill_sync_items
      # Base::SyncItem.inferred_service_name_for reads peer notes via
      # peer_sync_id_keys_for, which plucks a fresh notes column per item
      # rather than using a loaded association, so preloading sync_items
      # here would not save any queries.
      Base::SyncItem.find_each do |item|
        backfill_source_provenance(item)
      end
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        backfill_mapping_provenance(collection)
      end
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

    def backfill_source_provenance(item)
      observed_at = item.last_observed_at || item.updated_at || item.created_at || Time.current
      attributes = {
        source_service_name: item.source_service_name.presence || Base::SyncItem.inferred_service_name_for(item),
        source_service_instance: item.source_service_instance.presence || Base::Service.instance_name_for(item.service_name),
        source_service_type: item.source_service_type.presence || item.provider,
        source_external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url,
        source_updated_at: item.source_updated_at || item.last_modified,
        first_observed_at: item.first_observed_at || observed_at,
        last_observed_at: item.last_observed_at || observed_at,
        source_metadata: item.source_metadata || {}
      }
      item.assign_attributes(attributes)
      item.save! if item.changed? && !dry_run?
    end

    def backfill_mapping_provenance(collection)
      observed_at = collection.updated_at || collection.created_at || Time.current
      provenance = inferred_provenance_for(collection)
      attributes = {
        mapping_method: collection.mapping_method.presence || provenance[:method],
        mapping_confidence: collection.mapping_confidence.presence || confidence_for(collection.mapping_method) || provenance[:confidence],
        mapping_metadata: collection.mapping_metadata || provenance[:metadata],
        mapping_established_at: collection.mapping_established_at || collection.created_at || observed_at,
        mapping_last_observed_at: collection.mapping_last_observed_at || observed_at
      }
      collection.assign_attributes(attributes)
      collection.save! if collection.changed? && !dry_run?
    end

    def emit_baseline_snapshots
      Base::SyncItem.find_each do |item|
        identity = Outbox::SourceIdentity.for(item)
        if identity[:external_id].blank?
          summary[:skipped][:items_missing_external_id] += 1
          next
        end

        summary[:items][identity[:service_type]] += 1
        next if dry_run?

        OutboxEntry.enqueue(
          record_kind: :item, payload: baseline_payload(item, identity),
          service_type: identity[:service_type], service_instance: identity[:service_instance],
          external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
          source_updated_at: item.source_updated_at || item.last_modified, observed_at: item.last_observed_at
        )
      end
    end

    def emit_mapping_observations
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence || inferred_provenance_for(collection)[:confidence]
        summary[:mappings][confidence || "incomplete"] += collection.sync_items.size
        if confidence == "low"
          summary[:skipped][:low_confidence_mappings] += collection.sync_items.size
          next
        end
        if confidence.blank?
          summary[:skipped][:mappings_missing_confidence] += collection.sync_items.size
          next
        end

        next if dry_run?

        Outbox::MappingEmitter.emit_for_members(
          collection, members: collection.sync_items, observed_at: collection.mapping_last_observed_at
        )
      end
    end

    def confidence_for(method)
      {
        "source_sync_id" => "high",
        "created_by_sync" => "high",
        "title_fallback" => "medium",
        "manual_backfill" => "low"
      }[method]
    end

    def baseline_payload(item, identity)
      snapshot = item.normalized_snapshot.deep_transform_values { |value| timestamp(value) }
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(item.last_observed_at), source: identity,
        provenance: { detected_by: BASELINE_DETECTED_BY, backfilled_at: timestamp(Time.current) }
      )
    end

    def timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end

    def dry_run?
      @dry_run
    end

    def dry_run_output
      "Backfill dry run: items by service=#{summary[:items].sort.to_h}, " \
        "mappings by confidence=#{summary[:mappings].sort.to_h}, skipped=#{summary[:skipped].sort.to_h}"
    end
  end
end
