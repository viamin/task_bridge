# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox from existing synchronized state. It never contacts a
  # provider; reruns reuse stable observed timestamps and outbox keys.
  class Observations
    Result = Data.define(:items, :mappings, :skipped, :confidence)

    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @items = Hash.new(0)
      @mappings = Hash.new(0)
      @skipped = Hash.new(0)
      @confidence = Hash.new(0)
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      result = Result.new(items:, mappings:, skipped:, confidence:)
      print(result) if dry_run
      result
    end

    private

    attr_reader :dry_run, :output, :items, :mappings, :skipped, :confidence

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          skip(:missing_external_id)
          next
        end

        items[service_for(item)] += 1
        Outbox::ItemEmitter.emit_baseline(item, observed_at: observed_at_for(item)) unless dry_run
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        provenance = provenance_for(collection)
        confidence[provenance.fetch(:confidence)] += 1
        if publishable?(provenance)
          collection.sync_items.each { |item| mappings[service_for(item)] += 1 if item.external_id.present? }
          unless dry_run
            Outbox::MappingEmitter.emit_for_members(
              collection,
              members: collection.sync_items,
              observed_at: mapping_observed_at_for(collection)
            )
          end
        else
          skip(:low_confidence_mapping)
        end
      end
    end

    def observed_at_for(item)
      item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_observed_at_for(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def provenance_for(collection)
      return { confidence: collection.mapping_confidence } unless dry_run && collection.mapping_method.blank?

      SyncBackfill::SourceProvenance.provenance_for(collection)
    end

    def publishable?(provenance)
      provenance.fetch(:confidence).in?(%w[high medium])
    end

    def service_for(item)
      Outbox::SourceIdentity.for(item).fetch(:service_type)
    end

    def skip(reason)
      skipped[reason] += 1
    end

    def print(result)
      output.puts "Backfill dry run"
      output.puts "items: #{result.items.sort.to_h}"
      output.puts "mappings: #{result.mappings.sort.to_h}"
      output.puts "mapping confidence: #{result.confidence.sort.to_h}"
      output.puts "skipped: #{result.skipped.sort.to_h}"
    end
  end
end
