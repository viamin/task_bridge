# frozen_string_literal: true

module SyncBackfill
  class SourceProvenance
    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = Hash.new(0)
    end

    def run!
      backfill_sync_items
      backfill_sync_collections
      backfill_snapshots
      backfill_mappings
      print_summary
      summary
    end

    private

    attr_reader :dry_run, :output, :summary

    def backfill_sync_items
      # Base::SyncItem.inferred_service_name_for reads peer notes via
      # peer_sync_id_keys_for, which plucks a fresh notes column per item
      # rather than using a loaded association, so preloading sync_items
      # here would not save any queries.
      Base::SyncItem.find_each do |item|
        next if item.last_observed_at.present? || dry_run

        observed_at = item.updated_at || item.created_at || Time.current
        item.source_service_name ||= Base::SyncItem.inferred_service_name_for(item)
        item.observe_source!(observed_at:)
      end
    end

    def backfill_sync_collections
      SyncCollection.includes(:sync_items).find_each do |collection|
        next if collection.mapping_method.present? || dry_run

        observed_at = collection.updated_at || collection.created_at || Time.current
        provenance = inferred_provenance_for(collection)
        collection.update_mapping_provenance!(**provenance, observed_at:)
      end
    end

    def inferred_provenance_for(collection)
      items = collection.sync_items.to_a.compact
      default_metadata = { "sync_item_ids" => items.filter_map(&:id) }
      return { method: "manual_backfill", confidence: "low", metadata: default_metadata } if items.length < 2

      provenance = preferred_provenance(items)

      provenance.merge(metadata: default_metadata.merge(provenance.fetch(:metadata)))
    end

    def preferred_provenance(items)
      SyncMappingProvenance.preferred_for(items)
    end

    def backfill_snapshots
      Base::SyncItem.find_each do |item|
        observed_at = item.first_observed_at || item.updated_at || item.created_at || Time.current
        result = Outbox::BaselineSnapshotEmitter.emit_for(item, observed_at:, dry_run:)
        summary["items.#{result}"] += 1
        summary["service.#{Outbox::SourceIdentity.for(item)[:service_type]}.#{result}"] += 1
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        members = collection.sync_items.to_a
        confidence = mapping_confidence_for(collection, members)
        if mapping_publishable?(confidence)
          result = dry_run ? :preview : :enqueued
          unless dry_run
            Outbox::MappingEmitter.emit_backfill_for_members(
              collection,
              members:,
              observed_at: mapping_observed_at(collection)
            )
          end
          summary["mappings.#{confidence}.#{result}"] += members.length
        else
          summary["mappings.#{confidence}.withheld"] += members.length
        end
      end
    end

    def mapping_publishable?(confidence)
      %w[high medium].include?(confidence)
    end

    def mapping_confidence_for(collection, members)
      return collection.mapping_confidence if collection.mapping_confidence.present?
      return "low" if members.length < 2

      inferred_provenance_for(collection).fetch(:confidence)
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.mapping_established_at || collection.updated_at || Time.current
    end

    def print_summary
      output.puts "TaskBridge sync backfill#{' dry run' if dry_run}:"
      summary.sort.each { |key, value| output.puts "  #{key}: #{value}" }
    end
  end
end
