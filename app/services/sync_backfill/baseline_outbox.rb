# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web with current local state without manufacturing
  # historical change observations. It writes only local outbox rows.
  class BaselineOutbox
    BACKFILL_DETECTED_BY = "backfill"

    def self.run!(dry_run: false, backfilled_at: Time.current)
      new(dry_run:, backfilled_at:).run!
    end

    def initialize(dry_run:, backfilled_at:)
      @dry_run = dry_run
      @backfilled_at = backfilled_at
      @summary = {
        item_snapshots: Hash.new(0),
        mappings: Hash.new(0),
        skipped: Hash.new(0)
      }
    end

    def run!
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :backfilled_at, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        identity = Outbox::SourceIdentity.for(item)
        if identity[:external_id].blank?
          summary[:skipped]["incomplete_items"] += 1
          next
        end

        summary[:item_snapshots][identity[:service_type]] += 1
        enqueue_item(item, identity) unless @dry_run
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = mapping_confidence_for(collection)
        members = collection.sync_items.select { |item| item.external_id.present? }
        if confidence == "low"
          summary[:skipped]["low_confidence_mappings"] += members.size
          next
        end

        members.each do |member|
          summary[:mappings][confidence] += 1
          enqueue_mapping(collection, member) unless @dry_run
        end
      end
    end

    def enqueue_item(item, identity)
      observed_at = observation_time_for(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, identity, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def enqueue_mapping(collection, member)
      Outbox::MappingEmitter.emit_for_members(collection, members: [member], observed_at: mapping_time_for(collection))
    end

    def item_payload(item, identity, observed_at)
      serialized_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        source: identity,
        provenance: {
          detected_by: BACKFILL_DETECTED_BY,
          baseline: true,
          backfilled_at: timestamp(backfilled_at)
        }
      )
    end

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? timestamp(value) : value
      end
    end

    def mapping_confidence_for(collection)
      collection.mapping_confidence.presence || SourceProvenance.mapping_provenance_for(collection).fetch(:confidence)
    end

    def observation_time_for(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at || backfilled_at
    end

    def mapping_time_for(collection)
      collection.mapping_established_at || collection.mapping_last_observed_at || collection.updated_at || collection.created_at || backfilled_at
    end

    def timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
