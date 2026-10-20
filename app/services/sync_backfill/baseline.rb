# frozen_string_literal: true

module SyncBackfill
  # Seeds the local outbox with baseline records for deployments that already
  # hold synchronized data (#222): one current-state `item` snapshot per
  # existing sync item (never synthetic observations or sync runs) plus a
  # `mapping` row per member of an established collection. Baselines are
  # idempotent: rows keep their deterministic idempotency keys across reruns,
  # and a stored last_snapshot is only seeded when blank so a concurrent sync
  # run's baseline is never overwritten.
  class Baseline
    ELIGIBLE_MAPPING_CONFIDENCES = %w[high medium].freeze

    def self.run!(backfilled_at: Time.current)
      new(backfilled_at:).run!
    end

    def initialize(backfilled_at:)
      @backfilled_at = backfilled_at
    end

    def run!
      backfill_items
      backfill_mappings
    end

    private

    attr_reader :backfilled_at

    def backfill_items
      Base::SyncItem.find_each do |item|
        next if item.external_id.blank?

        enqueue_item(item)
      end
    end

    def enqueue_item(item)
      observed_at = item.last_observed_at || item.first_observed_at || item.updated_at || item.created_at || backfilled_at
      identity = Outbox::SourceIdentity.for_backfill(item)
      # The same rendering the sync flow uses for its own diff baseline, so a
      # backfilled baseline is indistinguishable from one a sync would have
      # written and the first post-backfill sync reports no spurious changes.
      snapshot = Base::SnapshotSerializer.published(item)
      entry = Outbox::IsolatedWrite.call("baseline snapshot for #{item.item_key}") do
        OutboxEntry.enqueue(
          record_kind: :item,
          payload: item_payload(snapshot, identity, observed_at),
          service_type: identity.fetch(:service_type),
          service_instance: identity.fetch(:service_instance),
          external_id: identity.fetch(:external_id),
          sync_collection_id: item.sync_collection_id,
          source_updated_at: item.source_updated_at || item.last_modified,
          observed_at:
        )
      end
      seed_snapshot_baseline(item, snapshot) if entry
    end

    def item_payload(snapshot, identity, observed_at)
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        item_key: Outbox::SourceIdentity.item_key(identity),
        source: identity,
        observed_at: timestamp(observed_at),
        provenance: {
          detected_by: "backfill",
          backfilled_at: timestamp(backfilled_at)
        }
      )
    end

    # The row is locked so a concurrent sync run's baseline is never
    # overwritten. The upfront check keeps a rerun — where every baseline is
    # already seeded — from taking a lock it would never write under.
    def seed_snapshot_baseline(item, snapshot)
      return if item.last_snapshot.present?

      item.with_lock do
        item.update_column(:last_snapshot, snapshot) if item.last_snapshot.blank?
      end
    end

    def backfill_mappings
      eligible_mapping_members.find_each do |item|
        collection = item.sync_collection
        Outbox::MappingEmitter.emit_backfill_for_members(
          collection,
          members: [item],
          observed_at: collection.mapping_established_at || collection.created_at || backfilled_at
        )
      end
    end

    def eligible_mapping_members
      Base::SyncItem.joins(:sync_collection)
                    .where(sync_collections: { mapping_confidence: ELIGIBLE_MAPPING_CONFIDENCES })
                    .where.not(sync_collections: { mapping_method: nil })
                    .includes(:sync_collection)
    end

    def timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
