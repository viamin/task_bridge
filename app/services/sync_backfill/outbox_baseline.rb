# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox from the local current state. These rows deliberately
  # describe a baseline, never a historical change or a sync run.
  class OutboxBaseline
    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @report = Report.new
    end

    def run!
      SourceProvenance.run! unless dry_run?
      backfill_items
      backfill_mappings
      report.to_h
    end

    private

    attr_reader :report

    def dry_run?
      @dry_run
    end

    def backfill_items
      Base::SyncItem.find_each do |item|
        item.external_id.present? ? backfill_item(item) : report.skip_item(item, :missing_external_id)
      end
    end

    def backfill_item(item)
      observed_at = item.last_observed_at || item.updated_at || item.created_at
      identity = Outbox::SourceIdentity.for(item)
      report.item(identity[:service_type])
      return if dry_run?

      snapshot = published_snapshot(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: snapshot.merge(provenance: baseline_provenance(observed_at)),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
      item.update_column(:last_snapshot, snapshot) if item.last_snapshot.blank?
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        collection.sync_items.each { |item| backfill_mapping(collection, item) }
      end
    end

    def backfill_mapping(collection, item)
      return report.skip_mapping(collection, :missing_external_id) if item.external_id.blank?

      provenance = mapping_provenance(collection)
      confidence = provenance.fetch(:confidence)
      return report.withhold_mapping(confidence) if confidence == "low"

      return report.skip_mapping(collection, :missing_provenance) if provenance[:method].blank?

      report.mapping(confidence)
      return if dry_run?

      Outbox::MappingEmitter.emit_for_members(
        collection,
        members: [item],
        observed_at: collection.mapping_last_observed_at || collection.updated_at || collection.created_at
      )
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| timestamp(value) }
    end

    def mapping_provenance(collection)
      return { method: collection.mapping_method, confidence: collection.mapping_confidence } unless dry_run?
      return { method: collection.mapping_method, confidence: collection.mapping_confidence } if collection.mapping_method.present? && collection.mapping_confidence.present?

      SourceProvenance.provenance_for(collection)
    end

    def baseline_provenance(observed_at)
      {
        detected_by: "backfill",
        baseline: true,
        backfilled_at: timestamp(observed_at)
      }
    end

    def timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end

    # Reporting stays deliberately compact so `rake ... DRY_RUN=1` works in
    # operational runbooks and can be parsed by automation.
    class Report
      def initialize
        @items_by_service = Hash.new(0)
        @mappings_by_confidence = Hash.new(0)
        @withheld_by_confidence = Hash.new(0)
        @skipped = Hash.new(0)
      end

      def item(service_type)
        @items_by_service[service_type] += 1
      end

      def mapping(confidence)
        @mappings_by_confidence[confidence] += 1
      end

      def withhold_mapping(confidence)
        @withheld_by_confidence[confidence] += 1
      end

      def skip_item(_item, reason)
        @skipped[reason] += 1
      end

      def skip_mapping(_collection, reason)
        @skipped[reason] += 1
      end

      def to_h
        {
          items_by_service: @items_by_service.sort.to_h,
          mappings_by_confidence: @mappings_by_confidence.sort.to_h,
          withheld_mappings_by_confidence: @withheld_by_confidence.sort.to_h,
          skipped: @skipped.sort.to_h
        }
      end
    end
  end
end
