# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state view from existing local sync data.
  # These are deliberately item snapshots, rather than historical
  # observations: the source timestamps do not tell us when TaskBridge first
  # learned each fact.
  class Outbox
    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @report = {
        services: Hash.new(0), mappings: Hash.new(0), mapping_methods: Hash.new(0),
        skipped: Hash.new(0), enqueued: Hash.new(0)
      }
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      Base::SyncItem.find_each { |item| backfill_item(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
      report
    end

    private

    attr_reader :dry_run, :report

    def backfill_item(item)
      return skip(:incomplete_items) if item.external_id.blank?

      identity = ::Outbox::SourceIdentity.for(item)
      report[:services][identity[:service_type]] += 1
      return if dry_run

      ::OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, identity),
        service_type: identity[:service_type], service_instance: identity[:service_instance],
        external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified, observed_at: observed_at(item)
      )
      advance_snapshot_baseline(item)
      report[:enqueued][:items] += 1
    end

    def backfill_collection(collection)
      provenance = mapping_provenance_for(collection)
      confidence = provenance.fetch(:confidence)
      report[:mappings][confidence] += collection.sync_items.count
      report[:mapping_methods][provenance.fetch(:method)] += collection.sync_items.count
      return skip(:low_confidence_mappings, collection.sync_items.count) if confidence == "low"
      return if dry_run

      before = ::OutboxEntry.where(record_kind: "mapping").count
      ::Outbox::MappingEmitter.emit_for_members(
        collection, members: collection.sync_items, observed_at: mapping_observed_at(collection)
      )
      report[:enqueued][:mappings] += ::OutboxEntry.where(record_kind: "mapping").count - before
    end

    def mapping_provenance_for(collection)
      return { method: collection.mapping_method, confidence: collection.mapping_confidence.presence || "low" } if collection.mapping_method.present?

      SyncBackfill::SourceProvenance.provenance_for(collection).slice(:method, :confidence)
    end

    def item_payload(item, identity)
      snapshot = published_snapshot(item)
      snapshot.merge(
        contract_version: ::OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at(item)),
        source: identity,
        provenance: { detected_by: "backfill", backfilled_at: timestamp(Time.current) }
      )
    end

    def advance_snapshot_baseline(item)
      snapshot = published_snapshot(item)
      item.update_column(:last_snapshot, snapshot) unless item.last_snapshot == snapshot
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| timestamp(value) }
    end

    def observed_at(record)
      record.last_observed_at || record.updated_at || record.created_at || Time.current
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
    end

    def timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end

    def skip(kind, count = 1)
      report[:skipped][kind] += count
    end
  end
end
