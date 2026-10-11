# frozen_string_literal: true

module SyncBackfill
  class SourceProvenance
    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @report = Report.new
    end

    def run!
      backfill_sync_items
      backfill_sync_collections
      report.to_h
    end

    private

    attr_reader :report

    def backfill_sync_items
      Base::SyncItem.find_each do |item|
        backfill_item(item)
      end
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
        provenance = collection.mapping_method.present? ? existing_provenance_for(collection) : inferred_provenance_for(collection)
        confidence = collection.mapping_confidence || provenance[:confidence]
        report.mapping(confidence)
        report.mapping_members(collection, confidence:)
        next if @dry_run

        collection.update_mapping_provenance!(**provenance, observed_at:) if collection.mapping_method.blank?
        Outbox::MappingEmitter.emit_backfill_for_members(collection, members: collection.sync_items, observed_at:)
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

    def backfill_item(item)
      if item.external_id.blank?
        report.skipped("missing_external_id")
        return
      end

      observed_at = item.last_observed_at || item.updated_at || item.created_at || Time.current
      service_name = item.source_service_name.presence || Base::SyncItem.inferred_service_name_for(item)
      report.item(Base::Service.service_identifier_for(service_name))
      return if @dry_run

      item.source_service_name ||= service_name
      item.observe_source!(observed_at:)
      Outbox::BaselineSnapshot.emit_for(item, observed_at:)
    end

    def existing_provenance_for(collection)
      {
        method: collection.mapping_method,
        confidence: collection.mapping_confidence,
        metadata: collection.mapping_metadata || {}
      }
    end

    class Report
      def initialize
        @items_by_service = Hash.new(0)
        @mappings_by_confidence = Hash.new(0)
        @skipped = Hash.new(0)
      end

      def item(service) = @items_by_service[service] += 1

      def mapping(confidence) = @mappings_by_confidence[confidence || "unknown"] += 1

      def mapping_members(collection, confidence:)
        skipped("low_confidence_mapping", collection.sync_items.size) if confidence == "low"
      end

      def skipped(reason, count = 1) = @skipped[reason] += count

      def to_h
        { items_by_service: @items_by_service, mappings_by_confidence: @mappings_by_confidence, skipped: @skipped }
      end
    end
  end
end
