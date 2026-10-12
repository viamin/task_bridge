# frozen_string_literal: true

module SyncBackfill
  # Seeds the publication outbox from pre-observation sync state.  The rows
  # are current-state baselines, not reconstructed history.
  class Outbox
    PUBLISHED_MAPPING_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, backfilled_at: Time.current)
      new(dry_run:, backfilled_at:).run!
    end

    def initialize(dry_run:, backfilled_at:)
      @dry_run = dry_run
      @backfilled_at = backfilled_at
      @summary = { items: Hash.new(0), mappings: Hash.new(0), withheld_mappings: Hash.new(0), skipped: Hash.new(0) }
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :backfilled_at, :dry_run, :summary

    def backfill_items
      Base::SyncItem.find_each { |item| backfill_item(item) }
    end

    def backfill_item(item)
      return skipped!(:missing_external_id) if item.external_id.blank?

      identity = ::Outbox::SourceIdentity.for(item)
      observed_at = item.last_observed_at || item.updated_at || item.created_at
      payload = item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
      payload[:observed_at] = iso_timestamp(observed_at)
      payload[:provenance] = { detected_by: "backfill", backfilled_at: iso_timestamp(backfilled_at) }
      enqueue_item(item, identity, payload, observed_at)
      item.update_column(:last_snapshot, payload.except(:provenance)) unless dry_run || item.last_snapshot.present?
      summary[:items][identity[:service_type]] += 1
    end

    def enqueue_item(item, identity, payload, observed_at)
      return if dry_run

      OutboxEntry.enqueue(
        record_kind: :item, payload:, service_type: identity[:service_type],
        service_instance: identity[:service_instance], external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id, source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_mapping(collection) }
    end

    def backfill_mapping(collection)
      confidence = collection.mapping_confidence
      if PUBLISHED_MAPPING_CONFIDENCES.include?(confidence)
        publish_mapping(collection, confidence)
      else
        summary[:withheld_mappings][confidence.presence || "incomplete"] += collection.sync_items.size
      end
    end

    def publish_mapping(collection, confidence)
      members = collection.sync_items.select { |item| item.external_id.present? }
      skipped!(:mapping_missing_external_id, collection.sync_items.size - members.size) if members.size < collection.sync_items.size
      ::Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at: mapping_observed_at(collection)) unless dry_run
      summary[:mappings][confidence] += members.size
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def skipped!(reason, count = 1)
      summary[:skipped][reason] += count
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
