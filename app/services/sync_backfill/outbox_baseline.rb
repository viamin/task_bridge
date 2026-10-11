# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from locally synchronized
  # records. These rows deliberately describe a baseline, not a historical
  # source event; normal sync observations begin after this seed has run.
  class OutboxBaseline
    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = Hash.new(0)
      @services = Hash.new(0)
      @confidences = Hash.new(0)
    end

    def run!
      SourceProvenance.run!(dry_run:)
      backfill_items
      backfill_mappings
      report
      summary
    end

    private

    attr_reader :dry_run, :output, :summary, :services, :confidences

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary[:items_missing_external_id] += 1
          next
        end

        identity = Outbox::SourceIdentity.for(item)
        services[identity.fetch(:service_type)] += 1
        next if dry_run

        observed_at = item.last_observed_at || item.updated_at || item.created_at
        OutboxEntry.enqueue(
          record_kind: :item,
          payload: item_payload(item, identity, observed_at),
          service_type: identity.fetch(:service_type),
          service_instance: identity.fetch(:service_instance),
          external_id: identity.fetch(:external_id),
          sync_collection_id: item.sync_collection_id,
          source_updated_at: item.source_updated_at || item.last_modified,
          observed_at:
        )
        summary[:item_snapshots] += 1
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence.presence || "low"
        confidences[confidence] += collection.sync_items.size
        if Outbox::MappingEmitter.publishable?(collection)
          emit_mapping(collection)
        else
          summary[:mappings_withheld_low_confidence] += collection.sync_items.size
        end
      end
    end

    def emit_mapping(collection)
      observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at
      members = collection.sync_items.select { |item| item.external_id.present? }
      summary[:mapping_members_missing_external_id] += collection.sync_items.size - members.size
      Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at:) unless dry_run
      summary[:mapping_observations] += members.size
    end

    def item_payload(item, identity, observed_at)
      snapshot = item.normalized_snapshot.deep_transform_values { |value| iso_timestamp(value) }
      snapshot.merge(
        observed_at: iso_timestamp(observed_at),
        source: identity,
        provenance: {
          detected_by: "backfill",
          baseline: true,
          backfilled_at: iso_timestamp(observed_at)
        }
      )
    end

    def iso_timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end

    def report
      return unless dry_run

      output.puts "TaskBridge outbox baseline dry run (no records were changed)"
      output.puts "Item snapshots by service: #{formatted(services)}"
      output.puts "Mappings by confidence: #{formatted(confidences)}"
      output.puts "Skipped/incomplete: #{formatted(summary.slice(*summary.keys.grep(/missing|withheld/)))}"
    end

    def formatted(counts)
      return "none" if counts.empty?

      counts.sort.map { |key, count| "#{key}=#{count}" }.join(", ")
    end
  end
end
