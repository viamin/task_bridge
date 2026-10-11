# frozen_string_literal: true

module Outbox
  # Backfills the baseline publication rows (#222) for data that predates
  # the observation pipeline (#219-#221): one `item` snapshot per existing
  # sync item and one `mapping` row per known SyncCollection membership, so
  # TaskBridge Web starts from known current state and only later diffs
  # count as change history (RDR #215, "Migration and Backfill
  # Implications").
  #
  # Baseline rows are marked, never passed off as history: every payload
  # carries `provenance.detected_by: "backfill"` plus the run's
  # `backfilled_at` timestamp, and the backfill emits no `snapshot_seen`
  # observations of its own.
  #
  # The run is idempotent: row keys derive from each record's own stored
  # observation timestamps rather than the wall clock, so reruns find their
  # rows already present and leave them untouched. The apply path first
  # runs the #218 provenance backfill so identity fields and mapping
  # metadata exist. Low-confidence memberships are withheld rather than
  # published (the resolved RDR #215 open question): memberships whose
  # contract confidence would be `tentative` — or whose provenance is still
  # unknown — never enter the outbox and surface only in the summary
  # counts for manual cleanup.
  #
  # The backfill only ever writes the local database: it reads persisted
  # state, never a provider, so it can never mutate an external source
  # system. Unlike the live emitters it does not swallow write failures —
  # a failed backfill aborts loudly and is simply rerun.
  #
  # Intentionally exceeds the ~100 line target: the two sinks document the
  # apply/preview boundary in one place next to their only caller.
  class Backfill
    DETECTED_BY = "backfill"
    WITHHELD_CONFIDENCE = "tentative"
    UNKNOWN_CONFIDENCE = "unknown"

    class << self
      def run!(now: Time.current)
        new(now:, sink: ApplySink).run!
      end

      def preview!(now: Time.current)
        new(now:, sink: PreviewSink).run!
      end
    end

    def initialize(now:, sink:)
      @now = now
      @sink = sink
      @provenance_pending = provenance_pending?
      @items = { publishable: 0, enqueued: 0, already_present: 0, skipped: 0 }
      @mappings = { publishable: 0, enqueued: 0, already_present: 0, withheld: 0, skipped: 0 }
      @items_by_service = Hash.new(0)
      @mappings_by_confidence = Hash.new(0)
    end

    def run!
      sink.backfill_provenance!
      backfill_items
      backfill_memberships
      summary
    end

    private

    attr_reader :now, :sink, :items, :mappings, :items_by_service, :mappings_by_confidence

    def backfill_items
      Base::SyncItem.find_each do |item|
        identity = Outbox::SourceIdentity.for(item)
        next items[:skipped] += 1 if identity[:external_id].blank?

        observed_at = item.last_observed_at || item.updated_at || item.created_at || now
        snapshot = published_snapshot(item, observed_at)
        items[:publishable] += 1
        items_by_service[identity[:service_type]] += 1
        entry = sink.enqueue(
          record_kind: :item,
          payload: item_payload(snapshot),
          **item_context(item, identity, observed_at)
        )
        count_entry(entry, items)
        sink.store_baseline!(item, snapshot)
      end
    end

    def backfill_memberships
      SyncCollection.includes(:sync_items).find_each do |collection|
        collection.sync_items.each { |member| backfill_membership(collection, member) }
      end
    end

    def backfill_membership(collection, member)
      identity = Outbox::SourceIdentity.for(member)
      return mappings[:skipped] += 1 if identity[:external_id].blank?

      confidence = contract_confidence(collection)
      return withhold(confidence) if confidence.blank? || confidence == WITHHELD_CONFIDENCE

      observed_at = collection.mapping_last_observed_at || collection.mapping_established_at ||
                    collection.created_at || now
      mappings[:publishable] += 1
      mappings_by_confidence[confidence] += 1
      entry = sink.enqueue(
        record_kind: :mapping,
        payload: mapping_payload(collection, member, identity, observed_at),
        **mapping_context(collection, identity, observed_at)
      )
      count_entry(entry, mappings)
    end

    def item_payload(snapshot)
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        provenance: backfill_provenance
      )
    end

    # The published and stored form of the snapshot, matching the diff
    # baseline format of Outbox::ObservationEmitter so the first live
    # refresh after the backfill compares like with like.
    def published_snapshot(item, observed_at)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end.except(:version).merge(observed_at: iso_timestamp(observed_at))
    end

    def mapping_payload(collection, member, identity, observed_at)
      payload = Outbox::MappingEmitter.payload(collection, member, identity, observed_at)
      payload[:provenance] = payload[:provenance].merge(backfill_provenance)
      payload
    end

    def item_context(item, identity, observed_at)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
    end

    def mapping_context(collection, identity, observed_at)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: collection.id,
        observed_at:
      }
    end

    def contract_confidence(collection)
      Outbox::MappingEmitter::CONFIDENCE.fetch(collection.mapping_confidence, collection.mapping_confidence)
    end

    def withhold(confidence)
      mappings[:withheld] += 1
      mappings_by_confidence[confidence || UNKNOWN_CONFIDENCE] += 1
    end

    def count_entry(entry, counter)
      return unless entry

      counter[entry.previously_new_record? ? :enqueued : :already_present] += 1
    end

    def backfill_provenance
      { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(now) }
    end

    def provenance_pending?
      Base::SyncItem.where(last_observed_at: nil).exists? ||
        SyncCollection.where(mapping_method: nil).exists?
    end

    def summary
      {
        mode: sink.mode,
        provenance_pending: @provenance_pending,
        items:,
        items_by_service: items_by_service.sort.to_h,
        mappings:,
        mappings_by_confidence: mappings_by_confidence.sort.to_h
      }
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end

    # Applies the backfill: runs the provenance backfill, enqueues real
    # outbox rows, and stores each item's diff baseline so the first live
    # refresh after the backfill publishes only genuine changes instead of
    # re-announcing the baseline as a fresh discovery.
    module ApplySink
      module_function

      def mode
        "apply"
      end

      def backfill_provenance!
        SyncBackfill::SourceProvenance.run!
      end

      def enqueue(record_kind:, payload:, **context)
        OutboxEntry.enqueue(record_kind:, payload:, **context)
      end

      def store_baseline!(item, snapshot)
        item.update_column(:last_snapshot, snapshot) if item.last_snapshot.blank?
      end
    end

    # Reports exactly what the apply sink would publish while writing
    # nothing: no provenance backfill, no outbox rows, no diff baselines.
    module PreviewSink
      module_function

      def mode
        "preview"
      end

      def backfill_provenance!; end

      def enqueue(**_context); end

      def store_baseline!(_item, _snapshot); end
    end
  end
end
