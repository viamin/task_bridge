# frozen_string_literal: true

module SyncBackfill
  # Coordinates the local-only initial publication baseline. It never calls a
  # provider and deliberately emits no sync-run or observation rows.
  class Baseline
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = { items: Hash.new(0), mappings: Hash.new(0), skipped: Hash.new(0) }
    end

    def run!
      SourceProvenance.run!(dry_run: dry_run?)
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        if Outbox::BaselineEmitter.eligible?(item)
          record_item(item)
        else
          summary[:skipped]["missing_external_id"] += 1
        end
      end
    end

    def record_item(item)
      service = service_type_for(item)
      summary[:items][service] += 1
      return if dry_run?

      Outbox::BaselineEmitter.emit_for(item, observed_at: item.last_observed_at || item.updated_at || Time.current)
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = mapping_confidence_for(collection)
        if PUBLISHABLE_CONFIDENCES.include?(confidence)
          collection.sync_items.each { |item| record_mapping(collection, item, confidence) if Outbox::BaselineEmitter.eligible?(item) }
        else
          summary[:skipped]["mapping_#{confidence}"] += collection.sync_items.size
        end
      end
    end

    def record_mapping(collection, item, confidence)
      summary[:mappings][confidence] += 1
      return if dry_run?

      Outbox::MappingEmitter.emit_for_members(
        collection,
        members: [item],
        observed_at: collection.mapping_last_observed_at || collection.updated_at || Time.current
      )
    end

    def service_type_for(item)
      Base::Service.service_identifier_for(item.source_service_name.presence || item.provider)
    end

    def mapping_confidence_for(collection)
      return collection.mapping_confidence if collection.mapping_confidence.present?

      SourceProvenance.mapping_provenance_for(collection).fetch(:confidence)
    end

    def dry_run?
      @dry_run
    end
  end
end
