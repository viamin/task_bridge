# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state outbox from records created before
  # observation publication existed. This is deliberately an initial-state
  # operation: it emits item snapshots, never historical observations or
  # synthetic sync runs.
  class Outbox
    def self.run!(dry_run: false, backfilled_at: Time.current)
      new(dry_run:, backfilled_at:).run!
    end

    def initialize(dry_run:, backfilled_at:)
      @dry_run = dry_run
      @backfilled_at = backfilled_at
      @summary = Summary.new
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      Base::SyncItem.find_each { |item| backfill_item(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
      summary.to_h
    end

    private

    attr_reader :backfilled_at, :dry_run, :summary

    def backfill_item(item)
      return summary.skip_item(item, "missing_external_id") if item.external_id.blank?

      observed_at = item.last_observed_at || item.updated_at || item.created_at
      return summary.skip_item(item, "missing_observed_at") if observed_at.blank?

      summary.item(item)
      return if dry_run

      identity = ::Outbox::SourceIdentity.for(item)
      snapshot = published_snapshot(item, observed_at)
      entry = OutboxEntry.enqueue(
        record_kind: :item,
        payload: snapshot,
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
      item.update_column(:last_snapshot, entry.payload) if item.last_snapshot.blank?
    end

    def published_snapshot(item, observed_at)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? timestamp(value) : value
      end.merge(
        observed_at: timestamp(observed_at),
        provenance: { detected_by: "backfill" },
        backfilled_at: timestamp(backfilled_at)
      )
    end

    def backfill_collection(collection)
      confidence = collection.mapping_confidence.presence || "low"
      members = collection.sync_items.select { |item| item.external_id.present? }
      return summary.skip_mapping(confidence, "incomplete_membership") if members.empty?

      summary.mapping(confidence, members.count)
      if confidence == "low"
        summary.withhold_low_confidence(members.count)
        return
      end
      return if dry_run

      ::Outbox::MappingEmitter.emit_for_members(
        collection,
        members:,
        observed_at: collection.mapping_last_observed_at || collection.updated_at || backfilled_at,
        backfilled_at:
      )
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end

    class Summary
      def initialize
        @items_by_service = Hash.new(0)
        @mappings_by_confidence = Hash.new(0)
        @skipped = Hash.new(0)
      end

      def item(item)
        @items_by_service[::Outbox::SourceIdentity.for(item)[:service_type]] += 1
      end

      def mapping(confidence, count)
        @mappings_by_confidence[confidence] += count
      end

      def skip_item(_item, reason)
        @skipped[reason] += 1
      end

      def skip_mapping(confidence, reason)
        @mappings_by_confidence[confidence] += 1
        @skipped[reason] += 1
      end

      def withhold_low_confidence(count)
        @skipped["withheld_low_confidence"] += count
      end

      def to_h
        {
          items_by_service: @items_by_service.sort.to_h,
          mappings_by_confidence: @mappings_by_confidence.sort.to_h,
          skipped: @skipped.sort.to_h
        }
      end
    end
  end
end
