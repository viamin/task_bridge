# frozen_string_literal: true

module SyncBackfill
  # Seeds the publication outbox from already-synchronized local records. It
  # only reads local state; provider APIs are never contacted by this task.
  class Baseline
    BACKFILL_DETECTED_BY = "backfill"

    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @backfilled_at = Time.current
      @summary = Hash.new(0)
    end

    def run!
      SourceProvenance.run!(dry_run:)
      backfill_items
      backfill_mappings
      write_summary
      summary
    end

    private

    attr_reader :backfilled_at, :dry_run, :output, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary[:items_skipped_missing_external_id] += 1
          next
        end

        enqueue_item(item)
        summary[:"items_#{Outbox::SourceIdentity.for(item)[:service_type]}"] += 1
      end
    end

    def enqueue_item(item)
      observed_at = item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at || backfilled_at
      snapshot = item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
      snapshot[:observed_at] = iso_timestamp(observed_at)
      snapshot[:provenance] = {
        detected_by: BACKFILL_DETECTED_BY,
        baseline: true,
        backfilled_at: iso_timestamp(backfilled_at)
      }
      return if @dry_run

      identity = Outbox::SourceIdentity.for(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: snapshot,
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
      store_baseline(item, snapshot.except(:provenance))
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        provenance = mapping_provenance(collection)
        confidence = provenance[:confidence]
        if confidence == "low"
          summary[:mappings_withheld_low] += collection.sync_items.length
          next
        end
        if provenance[:method].blank? || confidence.blank?
          summary[:mappings_skipped_incomplete] += collection.sync_items.length
          next
        end

        members = collection.sync_items.select { |item| item.external_id.present? }
        summary[:mappings_skipped_missing_external_id] += collection.sync_items.length - members.length
        observed_at = collection.mapping_last_observed_at || collection.mapping_established_at || collection.updated_at || backfilled_at
        Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at:) unless @dry_run
        summary[:"mappings_#{confidence}"] += members.length
      end
    end

    def write_summary
      output.puts "TaskBridge backfill#{' dry run' if @dry_run}: #{summary.sort.to_h.to_json}"
    end

    def mapping_provenance(collection)
      return { method: collection.mapping_method, confidence: collection.mapping_confidence } unless @dry_run

      return { method: collection.mapping_method, confidence: collection.mapping_confidence } if collection.mapping_method.present?

      SourceProvenance.inferred_mapping_provenance_for(collection)
    end

    def store_baseline(item, snapshot)
      snapshot = snapshot.deep_stringify_keys
      item.update_column(:last_snapshot, snapshot) unless item.last_snapshot == snapshot
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
