# frozen_string_literal: true

module SyncBackfill
  # Seeds current source state without manufacturing historical observations.
  # It only writes TaskBridge's local provenance, snapshot baseline, and outbox.
  class OutboxBaseline
    DETECTED_BY = "backfill"

    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = Summary.new
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
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
          summary.skip(:items, :missing_external_id)
          next
        end

        summary.item(service_type(item))
        next if dry_run

        observed_at = item.last_observed_at || item.updated_at || item.created_at || Time.current
        snapshot = published_snapshot(item)
        OutboxEntry.enqueue(record_kind: :item, payload: item_payload(snapshot, observed_at),
                            **item_context(item, observed_at))
        item.update_column(:last_snapshot, snapshot) if item.last_snapshot.blank?
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        members = collection.sync_items.select { |item| item.external_id.present? }
        if members.empty?
          summary.skip(:mappings, :no_complete_members)
          next
        end

        confidence = mapping_confidence(collection, members)
        summary.mapping(confidence, members.count)
        next if confidence == "low" || dry_run

        observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
        Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at:)
      end
    end

    def item_payload(snapshot, observed_at)
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        provenance: { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(Time.current) }
      )
    end

    def mapping_confidence(collection, members)
      return collection.mapping_confidence if collection.mapping_confidence.present?
      return "low" if members.one?

      SyncMappingProvenance.preferred_for(members).fetch(:confidence)
    end

    def item_context(item, observed_at)
      identity = Outbox::SourceIdentity.for(item)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? iso_timestamp(value) : value }
    end

    def service_type(item)
      Outbox::SourceIdentity.for(item).fetch(:service_type)
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end

    class Summary
      def initialize
        @items_by_service = Hash.new(0)
        @mappings_by_confidence = Hash.new(0)
        @skipped = Hash.new(0)
      end

      def item(service)
        @items_by_service[service] += 1
      end

      def mapping(confidence, count)
        @mappings_by_confidence[confidence] += count
      end

      def skip(scope, reason)
        @skipped["#{scope}.#{reason}"] += 1
      end

      def to_h
        {
          items_by_service: @items_by_service,
          mappings_by_confidence: @mappings_by_confidence,
          skipped: @skipped
        }
      end

      def to_json(*)
        to_h.to_json
      end
    end
  end
end
