# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox with a stable baseline for records that predate the
  # observation pipeline. It deliberately does not create observations or
  # sync-run records: existing rows describe current state, not history.
  class Observations
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
      backfill_items
      backfill_mappings
      print_summary
      summary
    end

    private

    attr_reader :dry_run, :output, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          count(:items_skipped_incomplete, item)
          next
        end

        count(:items, item)
        next if dry_run

        Outbox::ItemSnapshotEmitter.emit_for_item(
          item,
          observed_at: item.first_observed_at || item.last_observed_at || baseline_at(item),
          detected_by: "backfill",
          backfilled_at: item.first_observed_at || baseline_at(item)
        )
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        provenance = mapping_provenance_for(collection)
        collection.sync_items.each do |item|
          if item.external_id.blank?
            count(:mappings_skipped_incomplete, item, confidence: provenance.fetch(:confidence))
          elsif publishable_mapping?(provenance)
            count(:mappings, item, confidence: provenance.fetch(:confidence))
            Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: mapping_at(collection)) unless dry_run
          else
            count(:mappings_withheld_low_confidence, item, confidence: provenance.fetch(:confidence))
          end
        end
      end
    end

    def mapping_provenance_for(collection)
      return { confidence: collection.mapping_confidence } if collection.mapping_confidence.present?

      SyncBackfill::SourceProvenance.inferred_provenance_for(collection)
    end

    def publishable_mapping?(provenance)
      provenance.fetch(:confidence).in?(%w[high medium])
    end

    def baseline_at(item)
      item.updated_at || item.created_at || Time.current
    end

    def mapping_at(collection)
      collection.mapping_established_at || collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
    end

    def count(kind, item, confidence: "none")
      summary[[kind, item.provider.to_s.underscore, confidence || "none"]] += 1
    end

    def print_summary
      output.puts "TaskBridge observation backfill#{' dry run' if dry_run}:"
      summary.sort.each do |(kind, service, confidence), count|
        output.puts "  #{kind} service=#{service} confidence=#{confidence} count=#{count}"
      end
    end
  end
end
