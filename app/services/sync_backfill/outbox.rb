# frozen_string_literal: true

module SyncBackfill
  # Seeds the publication outbox from data that predates the observation
  # pipeline. This only reads local records and writes local outbox rows.
  class Outbox
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
      SourceProvenance.run! unless dry_run?
      backfill_items
      backfill_mappings
      print_summary
      summary
    end

    private

    attr_reader :output, :summary

    def dry_run?
      @dry_run
    end

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          count(:items_skipped_incomplete, item)
          next
        end

        count(:items, item)
        enqueue_item(item) unless dry_run?
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        collection.sync_items.each do |item|
          if item.external_id.blank?
            count(:mappings_skipped_incomplete, item, collection)
          elsif publishable_mapping?(collection)
            count(:mappings, item, collection)
            ::Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: mapping_observed_at(collection)) unless dry_run?
          else
            count(:mappings_withheld_low_confidence, item, collection)
          end
        end
      end
    end

    def enqueue_item(item)
      identity = ::Outbox::SourceIdentity.for(item)
      observed_at = item.last_observed_at || item.updated_at || item.created_at
      snapshot = serialized_snapshot(item)
      payload = snapshot.merge(
        provenance: { detected_by: "backfill", baseline: true },
        backfilled_at: @backfilled_at.utc.iso8601(6)
      )
      ::OutboxEntry.enqueue(
        record_kind: :item,
        payload:,
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
      item.update_column(:last_snapshot, snapshot.deep_stringify_keys) unless item.last_snapshot == snapshot.deep_stringify_keys
    end

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? value.utc.iso8601(6) : value
      end
    end

    def publishable_mapping?(collection)
      %w[high medium].include?(collection.mapping_confidence)
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def count(kind, item, collection = nil)
      summary[[kind, service_type_for(item), collection&.mapping_confidence || "none"]] += 1
    end

    def service_type_for(item)
      ::Outbox::SourceIdentity.for(item)[:service_type]
    end

    def print_summary
      output.puts "TaskBridge outbox backfill#{' dry run' if dry_run?}:"
      summary.sort.each do |(kind, service, confidence), count|
        output.puts "  #{kind} service=#{service} confidence=#{confidence}: #{count}"
      end
    end
  end
end
