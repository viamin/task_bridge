# frozen_string_literal: true

module SyncBackfill
  # Backfills one baseline `item` outbox row per existing sync item (#222)
  # so TaskBridge Web can seed current state before the live pipeline's
  # `observation` rows (#219) become the only source of change history.
  # Rows are marked with provenance.detected_by: "backfill" plus a
  # backfilled_at timestamp so Web never mistakes a baseline snapshot for a
  # historical change event. Idempotent: reruns reuse the same
  # idempotency_key (derived from the item's stable last_observed_at) and
  # OutboxEntry.enqueue dedupes on it.
  class ItemSnapshots
    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run: false)
      @dry_run = dry_run
      @by_service = Hash.new(0)
      @enqueued = 0
      @skipped_incomplete = 0
    end

    def run!
      Base::SyncItem.find_each { |item| process(item) }
      summary
    end

    private

    attr_reader :dry_run

    def process(item)
      return @skipped_incomplete += 1 unless eligible?(item)

      identity = Outbox::SourceIdentity.for(item)
      enqueue(item, identity) unless dry_run
      @by_service[identity[:service_type]] += 1
      @enqueued += 1
    end

    # Identity/provenance backfill (SyncBackfill::SourceProvenance) must run
    # first: an item without an observed source identity has nothing stable
    # to key a baseline snapshot by.
    def eligible?(item)
      item.external_id.present? && item.source_service_name.present? && item.last_observed_at.present?
    end

    def enqueue(item, identity)
      observed_at = item.last_observed_at
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: payload(item, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def payload(item, observed_at)
      Outbox::PublishedSnapshot.for(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: observed_at.utc.iso8601(6),
        provenance: { detected_by: "backfill", backfilled_at: Time.current.utc.iso8601(6) }
      )
    end

    def summary
      { enqueued: @enqueued, skipped_incomplete: @skipped_incomplete, by_service: @by_service }
    end
  end
end
