# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from existing local sync
  # data. It intentionally emits no observation or sync-run rows: neither can
  # be represented as a reliable historical fact by this migration.
  class Baseline
    Result = Data.define(:items_by_service, :mappings_by_confidence, :skipped)

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @items_by_service = Hash.new(0)
      @mappings_by_confidence = Hash.new(0)
      @skipped = Hash.new(0)
    end

    def run!
      SourceProvenance.run!(dry_run:)
      backfill_items
      backfill_mappings
      Result.new(items_by_service:, mappings_by_confidence:, skipped:)
    end

    private

    attr_reader :dry_run, :items_by_service, :mappings_by_confidence, :skipped

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          skipped[:missing_external_id] += 1
          next
        end

        identity = Outbox::SourceIdentity.for(item)
        items_by_service[identity[:service_type]] += 1
        next if dry_run

        Outbox::SnapshotEmitter.emit_for_backfill(item, observed_at: observed_at_for(item))
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        provenance = provenance_for(collection)
        confidence = provenance.fetch(:confidence)
        collection.sync_items.each do |item|
          if item.external_id.blank?
            skipped[:mapping_missing_external_id] += 1
          elsif confidence.blank?
            skipped[:mapping_missing_provenance] += 1
          elsif confidence == "low"
            mappings_by_confidence[:low_withheld] += 1
          else
            mappings_by_confidence[confidence.to_sym] += 1
            emit_mapping(collection, item) unless dry_run
          end
        end
      end
    end

    def provenance_for(collection)
      return SourceProvenance.provenance_for(collection) if collection.mapping_method.blank?

      {
        method: collection.mapping_method,
        confidence: collection.mapping_confidence,
        metadata: collection.mapping_metadata || {}
      }
    end

    def emit_mapping(collection, item)
      Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: observed_at_for(collection))
    end

    def observed_at_for(record)
      record.try(:last_observed_at) || record.try(:mapping_last_observed_at) || record.updated_at || record.created_at
    end
  end
end
