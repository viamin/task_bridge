# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state view without inventing a history.
  # Baseline item rows are intentionally `item` snapshots, never
  # `snapshot_seen` observations, and their timestamps come from durable local
  # state so deterministic keys make retries and reruns safe.
  class Observations
    def self.run!(dry_run: false, backfilled_at: Time.current)
      new(dry_run:, backfilled_at:).run!
    end

    def initialize(dry_run:, backfilled_at:)
      @dry_run = dry_run
      @backfilled_at = backfilled_at
      @report = Report.new
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      report.to_h
    end

    private

    attr_reader :dry_run, :backfilled_at, :report

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          report.skip(:items, "missing_external_id")
          next
        end

        identity = Outbox::SourceIdentity.for(item)
        report.item(identity.fetch(:service_type))
        next if dry_run

        OutboxEntry.enqueue(
          record_kind: :item,
          payload: item_payload(item, identity),
          service_type: identity.fetch(:service_type),
          service_instance: identity.fetch(:service_instance),
          external_id: identity.fetch(:external_id),
          sync_collection_id: item.sync_collection_id,
          source_updated_at: item.source_updated_at || item.last_modified,
          observed_at: observed_at_for(item)
        )
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence || SourceProvenance.provenance_for(collection).fetch(:confidence)
        members = collection.sync_items.to_a
        missing_identity = members.count { |member| member.external_id.blank? }
        report.skip(:mappings, "missing_external_id", missing_identity) if missing_identity.positive?
        members = members.reject { |member| member.external_id.blank? }
        report.mapping(confidence, members.count)
        if confidence == "low"
          report.skip(:mappings, "low_confidence", members.count)
          next
        end
        next if dry_run

        Outbox::MappingEmitter.emit_backfill_for_members(
          collection,
          members:,
          observed_at: mapping_observed_at(collection)
        )
      end
    end

    def item_payload(item, identity)
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at_for(item)),
        item_key: item.item_key,
        source: identity,
        source_created_at: timestamp(item.source_created_at),
        source_updated_at: timestamp(item.source_updated_at || item.last_modified),
        snapshot: serialized_snapshot(item),
        provenance: { detected_by: "backfill", backfilled_at: timestamp(backfilled_at) }
      }
    end

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? timestamp(value) : value }
    end

    def observed_at_for(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_observed_at(collection)
      collection.mapping_established_at || collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def timestamp(value)
      value&.utc&.iso8601(6)
    end

    class Report
      def initialize
        @items_by_service = Hash.new(0)
        @mappings_by_confidence = Hash.new(0)
        @skipped = Hash.new(0)
      end

      def item(service_type)
        @items_by_service[service_type] += 1
      end

      def mapping(confidence, count)
        @mappings_by_confidence[confidence] += count
      end

      def skip(kind, reason, count = 1)
        @skipped["#{kind}.#{reason}"] += count
      end

      def to_h
        { items_by_service: @items_by_service, mappings_by_confidence: @mappings_by_confidence, skipped: @skipped }
      end
    end
  end
end
