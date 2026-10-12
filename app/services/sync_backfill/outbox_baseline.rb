# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from data that predates the
  # observation pipeline. These rows describe a baseline, never historical
  # source changes, and use stable existing timestamps for rerun-safe keys.
  class OutboxBaseline
    CONFIDENCE = { "high" => "confirmed", "medium" => "inferred" }.freeze
    MAPPING_SOURCE = {
      "source_sync_id" => "sync_id_note",
      "title_fallback" => "title_match",
      "manual_backfill" => "manual"
    }.freeze

    def self.run!(dry_run: false, backfilled_at: Time.current)
      new(dry_run:, backfilled_at:).run!
    end

    def initialize(dry_run:, backfilled_at:)
      @dry_run = dry_run
      @backfilled_at = backfilled_at
      @summary = {
        items: { services: Hash.new(0), enqueued: 0 },
        mappings: { confidence: Hash.new(0), enqueued: 0 },
        skipped: Hash.new(0)
      }
    end

    def run!
      SourceProvenance.run! unless dry_run?
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :backfilled_at, :summary

    def dry_run?
      @dry_run
    end

    def backfill_items
      Base::SyncItem.find_each do |item|
        identity = Outbox::SourceIdentity.for(item)
        if identity[:external_id].blank?
          summary[:skipped][:items_missing_external_id] += 1
          next
        end

        summary[:items][:services][identity[:service_type]] += 1
        enqueue_item(item, identity) unless dry_run?
      end
    end

    def enqueue_item(item, identity)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, identity),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: item_observed_at(item)
      )
      summary[:items][:enqueued] += 1
    end

    def item_payload(item, identity)
      snapshot = serialize_timestamps(item.normalized_snapshot).except(:version, :metadata)
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(item_observed_at(item)),
        source: identity,
        provenance: { detected_by: "backfill", baseline: true, backfilled_at: timestamp(backfilled_at) }
      ).tap do |payload|
        payload[:source_metadata] = item.normalized_snapshot[:metadata] if item.normalized_snapshot[:metadata].present?
        add_mapping_to(payload, item.sync_collection)
      end
    end

    def add_mapping_to(payload, collection)
      return unless collection && CONFIDENCE.key?(collection.mapping_confidence)

      payload[:sync_collection] = {
        sync_collection_id: collection.id,
        membership_role: "member",
        mapping_confidence: CONFIDENCE.fetch(collection.mapping_confidence),
        mapping_source: MAPPING_SOURCE.fetch(collection.mapping_method, collection.mapping_method)
      }
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence
        unless CONFIDENCE.key?(confidence)
          summary[:skipped][confidence == "low" ? :mappings_low_confidence : :mappings_incomplete] += collection.sync_items.size
          next
        end

        eligible_items = collection.sync_items.select { |item| item.external_id.present? }
        summary[:skipped][:mappings_missing_external_id] += collection.sync_items.size - eligible_items.size
        eligible_items.each { |item| enqueue_mapping(collection, item) unless dry_run? }
        summary[:mappings][:confidence][confidence] += eligible_items.size
      end
    end

    def enqueue_mapping(collection, item)
      Outbox::MappingEmitter.emit_for_members(
        collection,
        members: [item],
        observed_at: collection.mapping_established_at || collection.created_at || backfilled_at
      )
      summary[:mappings][:enqueued] += 1
    end

    def item_observed_at(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at || backfilled_at
    end

    def serialize_timestamps(value)
      value.deep_transform_values { |field| field.respond_to?(:utc) ? timestamp(field) : field }
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end
  end
end
