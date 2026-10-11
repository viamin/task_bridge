# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from existing local sync
  # data. It intentionally creates item snapshots only: a backfill cannot
  # truthfully reconstruct source_changed or sync_run history.
  class ObservationBaseline
    DETECTED_BY = "backfill"

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = Summary.new
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary.to_h
    end

    private

    attr_reader :dry_run, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        identity = Outbox::SourceIdentity.for(item)
        unless identity[:external_id].present?
          summary.skip_item(identity[:service_type])
          next
        end

        observed_at = item.last_observed_at || item.updated_at || item.created_at
        summary.item(identity[:service_type])
        next if dry_run

        Outbox::ItemSnapshotEmitter.emit_for(item, observed_at:, detected_by: DETECTED_BY, backfilled_at: observed_at)
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence.presence || "low"
        members = collection.sync_items.select { |item| item.external_id.present? }
        if publishable_confidence?(confidence)
          summary.mapping(confidence, members.length)
          Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at: mapping_observed_at(collection)) unless dry_run
        else
          summary.withheld_mapping(confidence, members.length)
        end
      end
    end

    def publishable_confidence?(confidence)
      %w[high medium].include?(confidence)
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    class Summary
      def initialize
        @items_by_service = Hash.new(0)
        @skipped_items_by_service = Hash.new(0)
        @mappings_by_confidence = Hash.new(0)
        @withheld_mappings_by_confidence = Hash.new(0)
      end

      def item(service) = @items_by_service[service] += 1

      def skip_item(service) = @skipped_items_by_service[service] += 1

      def mapping(confidence, count) = @mappings_by_confidence[confidence] += count

      def withheld_mapping(confidence, count) = @withheld_mappings_by_confidence[confidence] += count

      def to_h
        {
          items_by_service: @items_by_service.sort.to_h,
          mappings_by_confidence: @mappings_by_confidence.sort.to_h,
          withheld_mappings_by_confidence: @withheld_mappings_by_confidence.sort.to_h,
          skipped_items_by_service: @skipped_items_by_service.sort.to_h
        }
      end
    end
  end
end
