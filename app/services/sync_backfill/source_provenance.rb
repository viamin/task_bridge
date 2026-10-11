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
      write_summary
      summary
    end

    private

    def backfill_sync_items
      # Base::SyncItem.inferred_service_name_for reads peer notes via
      # peer_sync_id_keys_for, which plucks a fresh notes column per item
      # rather than using a loaded association, so preloading sync_items
      # here would not save any queries.
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary[:items_skipped_incomplete] += 1
          next
        end

        observed_at = baseline_observed_at(item)
        backfilled_at = backfilled_at_for(item, observed_at)
        populate_item_provenance(item, observed_at, backfilled_at)
        enqueue_baseline_snapshot(item, observed_at, backfilled_at)
        summary[service_summary_key(item)] += 1
      end
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        observed_at = baseline_observed_at(collection)
        provenance = inferred_provenance_for(collection) if collection.mapping_method.blank?
        apply_mapping_provenance(collection, provenance, observed_at) if provenance
        confidence = collection.mapping_confidence || "low"
        summary["mappings_#{confidence}"] += collection.sync_items.length
        if mapping_publishable?(collection)
          enqueue_mapping_observations(collection, observed_at)
        else
          summary[:mappings_withheld_low] += collection.sync_items.length
        end
      end
    end

    def populate_item_provenance(item, observed_at, backfilled_at)
      item.source_service_name ||= Base::SyncItem.inferred_service_name_for(item)
      item.source_service_instance ||= Base::Service.instance_name_for(item.source_service_name)
      item.source_service_type ||= item.provider
      item.source_external_id ||= item.external_id
      item.source_url ||= item.url
      item.source_updated_at ||= item.last_modified
      item.first_observed_at ||= observed_at
      item.last_observed_at ||= observed_at
      metadata = (item.source_metadata || {}).dup
      metadata["baseline_backfilled_at"] ||= backfilled_at.utc.iso8601(6)
      item.source_metadata = metadata
      item.last_snapshot ||= published_snapshot(item)
      item.save!(validate: false) unless dry_run || !item.changed?
    end

    def enqueue_baseline_snapshot(item, observed_at, backfilled_at)
      summary[:baseline_snapshots] += 1
      return if dry_run

      identity = Outbox::SourceIdentity.for(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: baseline_snapshot_payload(item, observed_at, backfilled_at),
        service_type: identity[:service_type], service_instance: identity[:service_instance],
        external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified, observed_at:
      )
    end

    def baseline_snapshot_payload(item, observed_at, backfilled_at)
      published_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: observed_at.utc.iso8601(6),
        provenance: { detected_by: "backfill", backfilled_at: backfilled_at.utc.iso8601(6) }
      )
    end

    def enqueue_mapping_observations(collection, observed_at)
      summary[:mappings_published] += collection.sync_items.length
      return if dry_run

      Outbox::MappingEmitter.emit_for_members(collection, members: collection.sync_items, observed_at:)
    end

    def apply_mapping_provenance(collection, provenance, observed_at)
      return if dry_run

      collection.update_mapping_provenance!(**provenance, observed_at:)
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? value.utc.iso8601(6) : value
      end
    end

    def baseline_observed_at(record)
      return record.mapping_last_observed_at || record.updated_at || record.created_at || Time.current if record.is_a?(SyncCollection)

      record.last_observed_at || record.updated_at || record.created_at || Time.current
    end

    def backfilled_at_for(item, observed_at)
      value = item.source_metadata&.fetch("baseline_backfilled_at", nil)
      return Time.zone.parse(value) if value.present?

      Time.current
    rescue ArgumentError
      observed_at
    end

    def mapping_publishable?(collection)
      %w[high medium].include?(collection.mapping_confidence)
    end

    def service_summary_key(item)
      "items_#{Outbox::SourceIdentity.for(item)[:service_type]}"
    end

    def write_summary
      output.puts("Sync backfill#{' dry run' if dry_run}: #{summary.stringify_keys.sort.to_h.to_json}")
    end

    attr_reader :dry_run, :summary, :output

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
