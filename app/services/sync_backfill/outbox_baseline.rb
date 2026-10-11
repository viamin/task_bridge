# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web with the current local state without manufacturing
  # change-history observations. The idempotency key is anchored to the
  # existing observation timestamp, making reruns safe.
  class OutboxBaseline
    CONFIDENCE = { "high" => "confirmed", "medium" => "inferred", "low" => "tentative" }.freeze

    def self.run!(dry_run: false, backfilled_at: Time.current)
      new(dry_run:, backfilled_at:).run!
    end

    def initialize(dry_run:, backfilled_at:)
      @dry_run = dry_run
      @backfilled_at = backfilled_at
      @summary = { items: Hash.new(0), mappings: Hash.new(0), mapping_services: {}, skipped: Hash.new(0) }
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      Base::SyncItem.find_each { |item| process_item(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| process_collection(collection) }
      summary
    end

    private

    attr_reader :dry_run, :backfilled_at, :summary

    def process_item(item)
      return skip(:items_missing_external_id) if item.external_id.blank?

      observed_at = item.last_observed_at || item.updated_at || item.created_at
      return skip(:items_missing_timestamp) if observed_at.blank?

      identity = Outbox::SourceIdentity.for(item)
      summary[:items][identity[:service_type]] += 1
      return if dry_run

      snapshot = serialized_snapshot(item, identity, observed_at)
      OutboxEntry.enqueue(record_kind: :item, payload: snapshot,
                          **enqueue_context(identity, item, observed_at, snapshot[:idempotency_key]))
      item.update_column(:last_snapshot, snapshot.except(:contract_version, :idempotency_key, :provenance)) if item.last_snapshot.blank?
    end

    def process_collection(collection)
      provenance = collection_provenance(collection)
      confidence = CONFIDENCE.fetch(provenance[:confidence], "tentative")
      members = collection.sync_items.select { |item| item.external_id.present? }
      return skip(:mappings_without_members) if members.empty?

      members.each { |item| process_membership(collection, item, confidence) }
    end

    def process_membership(collection, item, confidence)
      return skip(:low_confidence_mappings) if confidence == "tentative"

      observed_at = collection.mapping_last_observed_at || item.last_observed_at || collection.updated_at || collection.created_at
      identity = Outbox::SourceIdentity.for(item)
      summary[:mappings][confidence] += 1
      summary[:mapping_services][identity[:service_type]] ||= Hash.new(0)
      summary[:mapping_services][identity[:service_type]][confidence] += 1
      return if dry_run

      Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at:)
    end

    def collection_provenance(collection)
      if collection.mapping_method.present?
        return {
          method: collection.mapping_method,
          confidence: collection.mapping_confidence,
          metadata: collection.mapping_metadata
        }
      end

      SyncBackfill::SourceProvenance.inferred_for(collection)
    end

    def serialized_snapshot(item, identity, observed_at)
      key = Outbox::IdempotencyKey.for(record_kind: :item, observed_at:, **identity)
      item.normalized_snapshot.deep_transform_values { |value| timestamp(value) }.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        idempotency_key: key,
        observed_at: timestamp(observed_at),
        source: identity,
        provenance: { detected_by: "backfill", baseline: true, backfilled_at: timestamp(backfilled_at) }
      )
    end

    def enqueue_context(identity, item, observed_at, idempotency_key)
      identity.slice(:service_type, :service_instance, :external_id).merge(
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:,
        idempotency_key:
      )
    end

    def timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end

    def skip(reason)
      summary[:skipped][reason] += 1
    end
  end
end
