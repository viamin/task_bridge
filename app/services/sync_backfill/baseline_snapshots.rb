# frozen_string_literal: true

module SyncBackfill
  # Emits one baseline `item` snapshot row (RDR #215) per existing
  # Base::SyncItem so TaskBridge Web can seed current state without
  # replaying history as change events (#222). Baseline rows are tagged
  # `provenance.detected_by: "backfill"` plus `backfilled_at`, and no
  # `snapshot_seen` observation is emitted for them — that distinction
  # between "baseline current state" and "history" is the point of this
  # class versus Outbox::ObservationEmitter (see
  # docs/backfill-outbox-baseline.md).
  #
  # Idempotent by construction: the idempotency key is derived from the
  # item's already-observed `last_observed_at` (or another stable source
  # timestamp), never from the time the backfill happens to run, so
  # rerunning finds the same OutboxEntry rows instead of duplicating them.
  #
  # Run SyncBackfill::SourceProvenance first so `source_service_instance`
  # is populated — otherwise an item with a real configured instance would
  # be backfilled under the default instance token instead of its own.
  class BaselineSnapshots
    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run: false)
      @dry_run = dry_run
      @enqueued = 0
      @by_service = Hash.new(0)
      @skipped = Hash.new(0)
    end

    def run!
      Base::SyncItem.includes(:sync_collection).find_each { |item| process(item) }
      report
    end

    private

    attr_reader :dry_run

    def process(item)
      skip_reason = skip_reason_for(item)
      return @skipped[skip_reason] += 1 if skip_reason

      identity = Outbox::SourceIdentity.for(item)
      @by_service[identity[:service_type]] += 1
      @enqueued += 1
      enqueue(item, identity) unless dry_run
    end

    def skip_reason_for(item)
      return "missing_external_id" if item.external_id.blank?
      return "missing_title" if item.title.blank?

      nil
    end

    def observed_at_for(item)
      item.last_observed_at || item.source_updated_at || item.last_modified ||
        item.updated_at || item.created_at || Time.current
    end

    def enqueue(item, identity)
      observed_at = observed_at_for(item)
      Outbox::IsolatedWrite.call("baseline snapshot for #{item.item_key}") do
        OutboxEntry.enqueue(
          record_kind: :item,
          payload: payload_for(item, identity, observed_at),
          service_type: identity[:service_type],
          service_instance: identity[:service_instance],
          external_id: identity[:external_id],
          sync_collection_id: item.sync_collection_id,
          source_updated_at: item.source_updated_at || item.last_modified,
          observed_at:
        )
      end
    end

    def payload_for(item, identity, observed_at)
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        item_key: item.item_key,
        entity_type: "task",
        observed_at: iso(observed_at),
        title: item.title,
        status: status_for(item),
        is_deleted: false,
        completed_at: iso(item.completed_at || item.completed_on),
        source_created_at: iso(item.source_created_at),
        source_updated_at: iso(item.source_updated_at || item.last_modified),
        due_at: iso(item.due_at),
        started_at: iso(item.start_at),
        tags: Array(item.tags),
        source: identity,
        sync_collection: sync_collection_for(item),
        source_metadata: item.normalized_metadata,
        provenance: {
          detected_by: "backfill",
          backfilled_at: iso(Time.current)
        }
      }.compact
    end

    def status_for(item)
      return "dropped" if item.respond_to?(:dropped?) && item.dropped?
      return "completed" if item.completed?

      "open"
    end

    # Omitted for low/blank confidence so a low-trust grouping never reaches
    # TaskBridge Web through the item row either, matching the standalone
    # mapping row withholding in SyncBackfill::MappingObservations (#222).
    def sync_collection_for(item)
      collection = item.sync_collection
      return if collection.blank?

      confidence = MappingObservations::CONFIDENCE[collection.mapping_confidence]
      return if confidence.nil?

      {
        sync_collection_id: collection.id,
        membership_role: Outbox::MappingEmitter::MEMBERSHIP_ROLE,
        mapping_confidence: confidence,
        mapping_source: Outbox::MappingEmitter::SOURCE.fetch(collection.mapping_method, collection.mapping_method)
      }
    end

    def iso(time)
      time&.utc&.iso8601(6)
    end

    def report
      {
        enqueued: @enqueued,
        by_service: @by_service,
        skipped: @skipped
      }
    end
  end
end
