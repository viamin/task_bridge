# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox from pre-observation-pipeline sync state. These rows are
  # current-state baselines, not historical observations, so only `item` and
  # sufficiently evidenced `mapping` records are emitted.
  class Observations
    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = Summary.new(dry_run:)
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      output.puts(summary.to_json)
      summary.to_h
    end

    private

    attr_reader :dry_run, :output, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary.skip_item
          next
        end

        observed_at = item.last_observed_at || item.updated_at || item.created_at
        summary.item(Outbox::SourceIdentity.for(item).fetch(:service_type))
        next if dry_run

        snapshot = published_snapshot(item)
        OutboxEntry.enqueue(record_kind: :item, payload: item_payload(item, snapshot, observed_at),
                            **item_context(item, observed_at))
        item.update_column(:last_snapshot, snapshot) if item.last_snapshot != snapshot
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence || "low"
        summary.mapping(confidence)
        next unless publishable_mapping?(confidence)
        next if dry_run

        Outbox::MappingEmitter.emit_for_members(
          collection,
          members: collection.sync_items,
          observed_at: collection.mapping_last_observed_at || collection.updated_at
        )
      end
    end

    def publishable_mapping?(confidence)
      %w[high medium].include?(confidence)
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| timestamp(value) }
    end

    def item_payload(_item, snapshot, observed_at)
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        provenance: { detected_by: "backfill", backfilled_at: timestamp(observed_at) }
      )
    end

    def item_context(item, observed_at)
      identity = Outbox::SourceIdentity.for(item)
      {
        service_type: identity.fetch(:service_type),
        service_instance: identity.fetch(:service_instance),
        external_id: identity.fetch(:external_id),
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
    end

    def timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end

    class Summary
      def initialize(dry_run:)
        @data = {
          dry_run:,
          items: { considered: 0 },
          mappings: { publishable: 0, withheld_low_confidence: 0 },
          services: Hash.new { |hash, key| hash[key] = 0 },
          confidence: Hash.new(0),
          skipped: { incomplete_items: 0 }
        }
      end

      def item(service_type)
        @data[:items][:considered] += 1
        @data[:services][service_type] += 1
      end

      def mapping(confidence)
        @data[:confidence][confidence] += 1
        key = confidence == "low" ? :withheld_low_confidence : :publishable
        @data[:mappings][key] += 1
      end

      def skip_item
        @data[:skipped][:incomplete_items] += 1
      end

      def to_h
        @data.deep_stringify_keys
      end

      def to_json(...)
        to_h.to_json(...)
      end
    end
  end
end
