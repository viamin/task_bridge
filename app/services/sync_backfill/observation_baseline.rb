# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from data that predates
  # observation publication. These are snapshots, not reconstructed history.
  class ObservationBaseline
    BACKFILL_DETECTED_BY = "backfill"
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze

    def self.run!
      new.run!
    end

    def self.preview
      new.preview
    end

    def run!
      SourceProvenance.run!
      Summary.new.tap do |summary|
        Base::SyncItem.find_each { |item| enqueue_item(item, summary) }
        SyncCollection.includes(:sync_items).find_each { |collection| enqueue_mappings(collection, summary) }
      end.to_h
    end

    def preview
      Summary.new.tap do |summary|
        Base::SyncItem.find_each { |item| summarize_item(item, summary) }
        SyncCollection.includes(:sync_items).find_each { |collection| summarize_mappings(collection, summary) }
      end.to_h
    end

    private

    def enqueue_item(item, summary)
      return summarize_item(item, summary) unless eligible_item?(item)

      observed_at = observation_time_for(item)
      identity = Outbox::SourceIdentity.for(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
      item.update_column(:last_snapshot, serialized_snapshot(item)) if item.last_snapshot.blank?
      summary.item(identity[:service_type])
    end

    def summarize_item(item, summary)
      return summary.skip_item("missing_external_id") unless eligible_item?(item)

      summary.item(Outbox::SourceIdentity.for(item)[:service_type])
    end

    def enqueue_mappings(collection, summary)
      return summarize_mappings(collection, summary) unless publishable?(collection)

      members = collection.sync_items.select { |item| eligible_item?(item) }
      Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at: mapping_time_for(collection))
      members.each { |item| summary.mapping(Outbox::SourceIdentity.for(item)[:service_type], collection.mapping_confidence) }
    end

    def summarize_mappings(collection, summary)
      return collection.sync_items.each { summary.skip_mapping(collection.mapping_confidence || "incomplete") } unless publishable?(collection)

      collection.sync_items.each do |item|
        if eligible_item?(item)
          summary.mapping(Outbox::SourceIdentity.for(item)[:service_type], collection.mapping_confidence)
        else
          summary.skip_mapping("missing_external_id")
        end
      end
    end

    def eligible_item?(item)
      item.persisted? && item.external_id.present?
    end

    def publishable?(collection)
      PUBLISHABLE_CONFIDENCES.include?(collection.mapping_confidence)
    end

    def observation_time_for(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_time_for(collection)
      collection.mapping_established_at || collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def item_payload(item, observed_at)
      serialized_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        provenance: {
          detected_by: BACKFILL_DETECTED_BY,
          initial_observation: true,
          backfilled_at: iso_timestamp(Time.current)
        }
      )
    end

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? iso_timestamp(value) : value }
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end

    # Keeps the task output useful for review without exposing item titles or
    # notes. Keys are deliberately stable so it can be diffed between runs.
    class Summary
      def initialize
        @items = Hash.new(0)
        @mappings = Hash.new { |hash, key| hash[key] = Hash.new(0) }
        @skipped = Hash.new(0)
      end

      def item(service)
        @items[service] += 1
      end

      def mapping(service, confidence)
        @mappings[confidence][service] += 1
      end

      def skip_item(reason)
        @skipped["item:#{reason}"] += 1
      end

      def skip_mapping(reason)
        @skipped["mapping:#{reason}"] += 1
      end

      def to_h
        { items_by_service: @items, mappings_by_confidence_and_service: @mappings, skipped: @skipped }
      end
    end
  end
end
