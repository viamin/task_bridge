# frozen_string_literal: true

module Outbox
  # Seeds the publication outbox from state that existed before observation
  # emission was introduced. These are current-state baselines, deliberately
  # not historical observation events.
  class Backfill
    BACKFILL_DETECTED_BY = "backfill"
    PUBLISHED_MAPPING_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
      @summary = Summary.new
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      Base::SyncItem.find_each { |item| backfill_item(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
      summary.to_h
    end

    private

    attr_reader :dry_run, :now, :summary

    def backfill_item(item)
      return summary.skip_item(item, "missing external ID") if item.external_id.blank?

      summary.item(item)
      return if dry_run

      observed_at = item.last_observed_at || item.updated_at || item.created_at || now
      payload = item_payload(item, observed_at)
      OutboxEntry.enqueue(record_kind: :item, payload:, **item_context(item, observed_at))
      item.update_column(:last_snapshot, published_snapshot(item)) if item.last_snapshot.blank?
    end

    def backfill_collection(collection)
      confidence = collection.mapping_confidence
      return summary.skip_mapping(confidence, "missing mapping confidence") if confidence.blank?

      members = collection.sync_items.select { |item| item.external_id.present? }
      summary.mapping(confidence, members.count)
      return summary.skip_mapping(confidence, "withheld low-confidence mapping") unless published_mapping?(confidence)
      return summary.skip_mapping(confidence, "no complete members") if members.empty?

      return if dry_run

      observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at || now
      Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at:)
    end

    def published_mapping?(confidence)
      PUBLISHED_MAPPING_CONFIDENCES.include?(confidence)
    end

    def item_payload(item, observed_at)
      published_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        backfilled_at: timestamp(now),
        provenance: { detected_by: BACKFILL_DETECTED_BY, baseline: true }
      )
    end

    def item_context(item, observed_at)
      identity = Outbox::SourceIdentity.for(item)
      identity.slice(:service_type, :service_instance, :external_id).merge(
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| timestamp(value) || value }
    end

    def timestamp(value)
      value.utc.iso8601(6) if value.respond_to?(:utc)
    end

    # Keeps the dry-run output useful to operators without turning the task
    # into an export format. Hashes sort naturally in the rake formatter.
    class Summary
      def initialize
        @items_by_service = Hash.new(0)
        @mappings_by_confidence = Hash.new(0)
        @skipped = Hash.new(0)
      end

      def item(item)
        @items_by_service[Outbox::SourceIdentity.for(item)[:service_type]] += 1
      end

      def mapping(confidence, count)
        @mappings_by_confidence[confidence] += count
      end

      def skip_item(item, reason)
        @skipped["#{reason} (#{item.provider})"] += 1
      end

      def skip_mapping(confidence, reason)
        @skipped["#{reason}#{" (#{confidence})" if confidence.present?}"] += 1
      end

      def to_h
        {
          items_by_service: @items_by_service.sort.to_h,
          mappings_by_confidence: @mappings_by_confidence.sort.to_h,
          skipped_or_incomplete: @skipped.sort.to_h
        }
      end
    end
  end
end
