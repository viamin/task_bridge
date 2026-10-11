# frozen_string_literal: true

module SyncBackfill
  # Seeds the TaskBridge Web outbox with a safe baseline for sync data that
  # predates the observation pipeline (#222): one `item` snapshot per
  # existing Base::SyncItem, and one `mapping` row per SyncCollection
  # membership TaskBridge holds with confirmed or inferred confidence.
  #
  # Idempotent: each row's idempotency key is derived from already-stable
  # identity and observed_at values (SyncBackfill::SourceProvenance should
  # run first so those columns are populated instead of falling back to
  # `updated_at`/`Time.current`), so OutboxEntry's unique index on
  # idempotency_key dedupes reruns -- a rerun's attempted INSERT loses the
  # unique-key race and the originally stored row is left untouched.
  #
  # Never mutates sync_items/sync_collections and never calls out to a
  # source provider API. `dry_run: true` skips every OutboxEntry write and
  # only tallies what a real run would create, for review before enabling
  # publication (see docs/backfilling-taskbridge-web.md).
  class OutboxBaseline
    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @backfilled_at = Time.current
    end

    def run!
      { items: seed_items, mappings: seed_mappings }
    end

    private

    attr_reader :dry_run, :backfilled_at

    def seed_items
      summary = { enqueued: 0, skipped: 0, by_service: Hash.new(0) }
      Base::SyncItem.find_each { |item| seed_item(item, summary) }
      summary
    end

    def seed_item(item, summary)
      unless ItemSnapshot.eligible?(item)
        summary[:skipped] += 1
        return
      end

      identity = Outbox::SourceIdentity.for(item)
      ItemSnapshot.enqueue(item, identity:, backfilled_at:) unless dry_run
      summary[:enqueued] += 1
      summary[:by_service][identity[:service_type]] += 1
    end

    def seed_mappings
      summary = { confirmed: 0, inferred: 0, withheld_low_confidence: 0, skipped: 0, by_service: Hash.new(0) }
      SyncCollection.includes(:sync_items).find_each { |collection| seed_collection(collection, summary) }
      summary
    end

    def seed_collection(collection, summary)
      if MappingMembership.incomplete?(collection)
        summary[:skipped] += collection.sync_items.size
        return
      end
      unless MappingMembership.publishable?(collection)
        summary[:withheld_low_confidence] += collection.sync_items.size
        return
      end

      collection.sync_items.each { |member| seed_membership(collection, member, summary) }
    end

    def seed_membership(collection, member, summary)
      unless MappingMembership.eligible_member?(member)
        summary[:skipped] += 1
        return
      end

      identity = Outbox::SourceIdentity.for(member)
      MappingMembership.enqueue(collection, member, identity:, backfilled_at:) unless dry_run
      summary[collection.mapping_confidence == "high" ? :confirmed : :inferred] += 1
      summary[:by_service][identity[:service_type]] += 1
    end
  end
end
