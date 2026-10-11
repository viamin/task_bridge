# frozen_string_literal: true

module SyncBackfill
  # Seeds the publication outbox from already-synchronized local state. It
  # deliberately writes snapshots, not historical observation events: the
  # baseline becomes the diff reference for the next live source refresh.
  class OutboxBaseline
    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = Summary.new
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary.to_h
    end

    private

    attr_reader :dry_run, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        item.external_id.present? ? backfill_item(item) : summary.skip_item(item, "missing_external_id")
      end
    end

    def backfill_item(item)
      observed_at = item.last_observed_at || item.updated_at || item.created_at || Time.current
      identity = Outbox::SourceIdentity.for(item)
      snapshot = published_snapshot(item)
      summary.item(identity[:service_type])
      return if dry_run

      OutboxEntry.enqueue(
        record_kind: :item,
        payload: snapshot.merge(provenance: baseline_provenance(observed_at)),
        service_type: identity[:service_type], service_instance: identity[:service_instance],
        external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified, observed_at:
      )
      item.update_column(:last_snapshot, snapshot) if item.last_snapshot.blank?
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence.presence || "low"
        members = collection.sync_items.to_a
        if %w[high medium].include?(confidence)
          summary.mapping(confidence, members.count)
          emit_mapping(collection, members) unless dry_run
        else
          summary.withhold_mapping(confidence, members.count)
        end
      end
    end

    def emit_mapping(collection, members)
      observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
      Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at:)
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? value.utc.iso8601(6) : value }
    end

    def baseline_provenance(observed_at)
      { detected_by: "backfill", baseline: true, backfilled_at: observed_at.utc.iso8601(6) }
    end

    # Kept deliberately small and JSON-ready so the rake task is useful in
    # automation as well as to a human operator running a dry preview.
    class Summary
      def initialize
        @items_by_service = Hash.new(0)
        @mappings_by_confidence = Hash.new(0)
        @withheld_by_confidence = Hash.new(0)
        @skipped = Hash.new(0)
      end

      def item(service_type)
        @items_by_service[service_type] += 1
      end

      def mapping(confidence, count)
        @mappings_by_confidence[confidence] += count
      end

      def withhold_mapping(confidence, count)
        @withheld_by_confidence[confidence] += count
      end

      def skip_item(item, reason)
        @skipped[reason] += 1
        @items_by_service[Outbox::SourceIdentity.for(item)[:service_type]] += 0
      end

      def to_h
        {
          items_by_service: @items_by_service.sort.to_h,
          mappings_by_confidence: @mappings_by_confidence.sort.to_h,
          withheld_mappings_by_confidence: @withheld_by_confidence.sort.to_h,
          skipped_incomplete_records: @skipped.sort.to_h
        }
      end
    end
  end
end
