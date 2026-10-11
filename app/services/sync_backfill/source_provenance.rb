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
      @services = Hash.new(0)
      @confidences = Hash.new(0)
    end

    def run!
      backfill_sync_items
      backfill_sync_collections
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
        backfill_item(item)
      end
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        backfill_collection(collection)
      end
    end

    def backfill_item(item)
      return skip(:incomplete_items) if item.external_id.blank?

      observed_at = item.last_observed_at || item.updated_at || item.created_at || Time.current
      apply_source_provenance(item, observed_at)
      identity = Outbox::SourceIdentity.for(item)
      @services[identity[:service_type]] += 1
      return count_existing_item if item.last_snapshot.present?

      @summary[:item_snapshots] += 1
      return if dry_run?

      snapshot = serialized_snapshot(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(snapshot, observed_at),
        service_type: identity[:service_type], service_instance: identity[:service_instance],
        external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified, observed_at:
      )
      item.update_column(:last_snapshot, snapshot)
    end

    def apply_source_provenance(item, observed_at)
      return if source_provenance_complete?(item)

      item.source_service_name ||= Base::SyncItem.inferred_service_name_for(item)
      item.observe_source!(observed_at:) unless dry_run?
    end

    def source_provenance_complete?(item)
      item.source_service_name.present? && item.source_service_type.present? && item.source_external_id.present?
    end

    def backfill_collection(collection)
      observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
      provenance = collection.mapping_method.present? ? existing_provenance_for(collection) : inferred_provenance_for(collection)
      @confidences[provenance[:confidence]] += collection.sync_items.length
      collection.update_mapping_provenance!(**provenance, observed_at:) unless dry_run? || collection.mapping_method.present?
      emit_mappings(collection, observed_at, provenance[:confidence])
    end

    def existing_provenance_for(collection)
      { method: collection.mapping_method, confidence: collection.mapping_confidence, metadata: collection.mapping_metadata || {} }
    end

    def emit_mappings(collection, observed_at, confidence)
      if confidence == "low"
        skip(:low_confidence_mappings, collection.sync_items.length)
        return
      end

      @summary[:mapping_rows] += collection.sync_items.length
      Outbox::MappingEmitter.emit_for_members(collection, members: collection.sync_items, observed_at:) unless dry_run?
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

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? value.utc.iso8601(6) : value }
    end

    def item_payload(snapshot, observed_at)
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: observed_at.utc.iso8601(6),
        provenance: { detected_by: "backfill", backfilled_at: Time.current.utc.iso8601(6) }
      )
    end

    def count_existing_item
      @summary[:existing_snapshots] += 1
    end

    def skip(type, count = 1)
      @summary[type] += count
    end

    def print_summary
      output.puts "TaskBridge sync backfill#{' (dry run)' if dry_run?}: #{summary.inspect}"
      output.puts "  services: #{services.sort.to_h.inspect}"
      output.puts "  mapping confidence: #{confidences.sort.to_h.inspect}"
    end

    def summary
      { counts: @summary, services: @services, mapping_confidence: @confidences }
    end

    attr_reader :confidences, :output, :services

    def dry_run?
      @dry_run
    end
  end
end
