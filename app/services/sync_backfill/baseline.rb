# frozen_string_literal: true

module SyncBackfill
  # Seeds baseline publication rows for existing synchronized data
  # (RDR #215 "Migration and Backfill Implications"): one current-state
  # `item` snapshot per known source item and `mapping` rows for known
  # SyncCollection memberships. Every row carries a deterministic
  # idempotency key anchored to the item's/collection's own observation
  # timestamps, so reruns are no-ops and only newly observed state
  # publishes again.
  #
  # Mapping backfill publishes only high-confidence (confirmed)
  # memberships: the RDR's open question about low-confidence backfill is
  # unresolved, and the documented safer default is to withhold tentative
  # mappings until they are upgraded by a live sync.
  class Baseline
    CONFIRMED_CONFIDENCE = "high"

    def self.run!
      new.run!
    end

    def run!
      { items: backfill_items, mappings: backfill_mappings }
    end

    private

    def backfill_items
      Base::SyncItem.includes(:sync_collection).find_each.count do |item|
        Outbox::ItemEmitter.emit_for_item(item)
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each.sum do |collection|
        next 0 unless confirmed?(collection)

        members = collection.sync_items.to_a
        Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at: mapping_observed_at(collection))
        members.length
      end
    end

    def confirmed?(collection)
      collection.mapping_confidence == CONFIRMED_CONFIDENCE
    end

    # Stable across reruns so the mapping idempotency keys stay
    # deterministic; falls back to the collection's own row timestamps.
    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
    end
  end
end
