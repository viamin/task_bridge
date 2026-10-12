# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state view from local synchronized data.
  # It deliberately emits item snapshots, not historical observations.
  class OutboxBaseline
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = { services: Hash.new(0), confidence: Hash.new(0), skipped: Hash.new(0),
                   items: 0, mappings: 0, withheld_mappings: 0 }
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :dry_run, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary[:skipped][:items_missing_external_id] += 1
          next
        end

        summary[:services][service_type_for(item)] += 1
        summary[:items] += 1
        Outbox::ItemSnapshotEmitter.emit_for(item, observed_at: observed_at_for(item)) unless dry_run
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = mapping_confidence_for(collection)
        summary[:confidence][confidence] += collection.sync_items.size
        unless PUBLISHABLE_CONFIDENCES.include?(confidence)
          summary[:withheld_mappings] += collection.sync_items.size
          next
        end

        collection.sync_items.each do |item|
          if item.external_id.blank?
            summary[:skipped][:mappings_missing_external_id] += 1
            next
          end

          summary[:mappings] += 1
        end
        unless dry_run
          Outbox::MappingEmitter.emit_for_members(
            collection,
            members: collection.sync_items,
            observed_at: observed_at_for(collection)
          )
        end
      end
    end

    def observed_at_for(record)
      return observed_collection_at(record) if record.is_a?(SyncCollection)

      record.first_observed_at || record.last_observed_at || record.updated_at || record.created_at || Time.current
    end

    def observed_collection_at(collection)
      collection.mapping_last_observed_at || collection.mapping_established_at || collection.updated_at ||
        collection.created_at || Time.current
    end

    def mapping_confidence_for(collection)
      return collection.mapping_confidence if collection.mapping_confidence.present?

      items = collection.sync_items.to_a
      return "low" if items.length < 2

      SyncMappingProvenance.preferred_for(items).fetch(:confidence)
    end

    def service_type_for(item)
      Outbox::SourceIdentity.for(item).fetch(:service_type)
    end
  end
end
