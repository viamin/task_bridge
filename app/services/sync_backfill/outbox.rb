# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's outbox from the current local state. These are
  # explicitly baseline snapshots, not reconstructed historical events.
  class Outbox
    BACKFILL_DETECTED_BY = "backfill"

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
      @summary = initial_summary
    end

    def run!
      SourceProvenance.run! unless dry_run
      Base::SyncItem.find_each { |item| snapshot(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| mappings(collection) }
      summary
    end

    private

    attr_reader :dry_run, :now, :summary

    def initial_summary
      {
        dry_run:,
        snapshots: { enqueued: 0, by_service: Hash.new(0), skipped_incomplete: 0 },
        mappings: { enqueued: 0, by_service: Hash.new(0), by_confidence: Hash.new(0), withheld_low_confidence: 0,
                    skipped_incomplete: 0 },
        sync_runs: 0
      }
    end

    def snapshot(item)
      identity = ::Outbox::SourceIdentity.for(item)
      return skip_snapshot unless identity[:external_id].present?

      summary[:snapshots][:by_service][identity[:service_type]] += 1
      summary[:snapshots][:enqueued] += 1
      return if dry_run

      observed_at = item.last_observed_at || item.updated_at || item.created_at || now
      key = ::Outbox::IdempotencyKey.for(record_kind: :item, observed_at:, **identity)
      OutboxEntry.enqueue(
        record_kind: :item, payload: item_payload(item, identity, key, observed_at), **enqueue_identity(identity),
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified, observed_at:
      )
    end

    def mappings(collection)
      confidence = collection.mapping_confidence.presence || "low"
      collection.sync_items.each { |item| mapping(collection, item, confidence) }
    end

    def mapping(collection, item, confidence)
      return skip_mapping unless item.external_id.present?

      summary[:mappings][:by_service][::Outbox::SourceIdentity.for(item)[:service_type]] += 1
      summary[:mappings][:by_confidence][confidence] += 1
      return withhold_mapping if confidence == "low"

      summary[:mappings][:enqueued] += 1
      return if dry_run

      ::Outbox::MappingEmitter.emit_for_members(
        collection, members: [item], observed_at: mapping_observed_at(collection)
      )
    end

    def item_payload(item, identity, key, observed_at)
      snapshot = published_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        idempotency_key: key,
        observed_at: iso_timestamp(observed_at),
        source: identity
      )
      snapshot[:provenance] = {
        detected_by: BACKFILL_DETECTED_BY,
        baseline: true,
        backfilled_at: iso_timestamp(now)
      }
      snapshot
    end

    def enqueue_identity(identity)
      identity.slice(:service_type, :service_instance, :external_id)
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? iso_timestamp(value) : value }
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || now
    end

    def skip_snapshot
      summary[:snapshots][:skipped_incomplete] += 1
    end

    def skip_mapping
      summary[:mappings][:skipped_incomplete] += 1
    end

    def withhold_mapping
      summary[:mappings][:withheld_low_confidence] += 1
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
