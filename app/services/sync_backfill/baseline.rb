# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox from local sync state. It never contacts a provider: the
  # rows describe the state TaskBridge already knows, not historical events.
  class Baseline
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = Hash.new(0)
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      Base::SyncItem.find_each { |item| backfill_item(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
      print_summary
      summary
    end

    private

    attr_reader :dry_run, :output, :summary

    def backfill_item(item)
      return count(:items_skipped_incomplete, item) if item.external_id.blank?

      count(:item_snapshots, item)
      return if dry_run

      Outbox::ItemSnapshotEmitter.emit_for(item, observed_at: observed_at_for(item))
    end

    def backfill_collection(collection)
      collection.sync_items.each do |item|
        next count(:mappings_skipped_incomplete, item) if item.external_id.blank?

        confidence = mapping_confidence_for(collection)
        next count(:mappings_skipped_incomplete, item, confidence:) if confidence.blank?
        next count(:mappings_withheld_low_confidence, item, confidence:) unless publishable?(confidence)

        count(:mapping_observations, item, confidence:)
        Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: observed_at_for(collection)) unless dry_run
      end
    end

    def observed_at_for(record)
      record.try(:last_observed_at) || record.try(:mapping_last_observed_at) || record.updated_at || record.created_at
    end

    def mapping_confidence_for(collection)
      return collection.mapping_confidence if collection.mapping_confidence.present?

      items = collection.sync_items.to_a.compact
      return "low" if items.length < 2

      SyncMappingProvenance.preferred_for(items).fetch(:confidence)
    end

    def publishable?(confidence)
      PUBLISHABLE_CONFIDENCES.include?(confidence)
    end

    def count(kind, item, confidence: "none")
      summary[[kind, service_for(item), confidence]] += 1
    end

    def service_for(item)
      Outbox::SourceIdentity.for(item).fetch(:service_type)
    end

    def print_summary
      output.puts "Sync backfill #{dry_run ? 'dry run' : 'complete'}:"
      summary.sort.each do |(kind, service, confidence), count|
        output.puts "  #{kind}: #{count} (service=#{service}, confidence=#{confidence})"
      end
    end
  end
end
