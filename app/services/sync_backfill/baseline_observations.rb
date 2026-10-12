# frozen_string_literal: true

module SyncBackfill
  # Backfills baseline item snapshots (RDR #215 "item" rows) for every
  # existing `Base::SyncItem` so TaskBridge Web can start from known
  # current state instead of an empty seed.
  #
  # The rows are deliberately marked as baseline — never as historical
  # change events — via `provenance.detected_by: "backfill"` and a
  # `backfilled_at` timestamp. Consumers can therefore distinguish
  # pre-existing synchronized work from later live observations.
  #
  # Idempotent: the unique index on `outbox_entries.idempotency_key`
  # dedupes reruns. Keys are derived from the item's stable observation
  # timestamp (`last_modified || updated_at || created_at`) plus the
  # backfill marker, so re-running the backfill never creates duplicate
  # `item` rows for the same source item.
  #
  # The baseline also advances `sync_items.last_snapshot` so future
  # live observation emission (#219) diffs against the backfilled
  # current state instead of re-publishing a `snapshot_seen`.
  class BaselineObservations
    PROVENANCE_DETECTED_BY = "backfill"

    # Stable fallback timestamp used when an item has neither
    # `last_modified` nor `created_at` populated, so its outbox
    # idempotency key stays identical across reruns. Pinned to the
    # #222 issue's milestone date so the baseline rows are easy to
    # identify in the outbox without affecting their validity.
    DEFAULT_OBSERVED_AT = Time.utc(2026, 10, 12, 0, 0, 0).freeze

    def self.run!(dry_run: false, **)
      new(**, dry_run:).run!
    end

    # Same shape as `#run!` but writes nothing. The Runner uses this to
    # preview how a live run would land before publication is enabled.
    def self.count_pretend(_now: Time.current)
      counts = empty_counts
      Base::SyncItem.find_each do |item|
        counts[:items_seen] += 1
        if eligible?(item)
          counts[:items_emitted] += 1
        else
          counts[:items_skipped] += 1
        end
      end
      counts
    end

    def self.eligible?(item)
      item.persisted? &&
        item.external_id.present? &&
        Base::Service.service_identifier_for(item.provider).present?
    end

    def self.empty_counts
      {
        items_seen: 0,
        items_emitted: 0,
        items_replayed: 0,
        items_skipped: 0
      }
    end

    def initialize(dry_run: false, now: Time.current, logger: nil)
      @dry_run = dry_run
      @now = now
      @logger = logger
      @counts = self.class.empty_counts
    end

    def run!
      Base::SyncItem.find_each { |item| snapshot_one(item) }
      counts
    end

    private

    attr_reader :dry_run, :now, :logger, :counts

    def snapshot_one(item)
      counts[:items_seen] += 1
      return skip_item(item) unless self.class.eligible?(item)

      if dry_run
        counts[:items_emitted] += 1
        return
      end

      payload = build_payload(item)
      context = build_context(item)
      entry = enqueue_or_replay(item, payload, context)

      if entry.nil?
        counts[:items_replayed] += 1
      else
        counts[:items_emitted] += 1
        advance_baseline(item)
      end
    end

    def skip_item(item)
      counts[:items_skipped] += 1
      logger&.debug(
        "skipping item #{item.id} (provider=#{item.provider.inspect}, " \
        "external_id=#{item.external_id.inspect}) during baseline backfill"
      )
    end

    def build_context(item)
      identity = Outbox::SourceIdentity.for(item)
      {
        service_type: identity.fetch(:service_type),
        service_instance: identity.fetch(:service_instance),
        external_id: identity.fetch(:external_id),
        observed_at: observed_at_for(item),
        source_updated_at: item.source_updated_at || item.last_modified
      }
    end

    def observed_at_for(item)
      # A stable timestamp keeps the outbox idempotency key stable so
      # reruns hit the unique index instead of creating duplicate rows.
      # `last_modified` is the source's last-modification timestamp and
      # never changes once populated. `created_at` is similarly stable.
      # `updated_at` is deliberately not used: it is bumped every time
      # a sync refresh saves the row, which would change the key between
      # reruns. `last_observed_at` is also deliberately not used: the
      # `before_validation :capture_source_identity` callback sets it to
      # `Time.current` on each save, so using it would defeat dedupe.
      item.last_modified || item.created_at || DEFAULT_OBSERVED_AT
    end

    def build_payload(item)
      identity = Outbox::SourceIdentity.for(item)
      snapshot = Base::SnapshotSerializer.call(item)
      status = normalized_status(item)

      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        item_key: snapshot[:item_key],
        entity_type: "task",
        observed_at: iso_timestamp(observed_at_for(item)),
        title: item.title,
        status: status,
        is_deleted: false,
        completed: item.completed?,
        completed_at: snapshot[:completed_at],
        source_created_at: snapshot[:source_created_at],
        source_updated_at: snapshot[:source_updated_at],
        due_at: snapshot[:due_at],
        due_date: snapshot[:due_date],
        start_at: snapshot[:start_at],
        start_date: snapshot[:start_date],
        tags: Array(snapshot[:tags]),
        parent: parent_field(item),
        source: identity,
        sync_collection: sync_collection_field(item),
        source_metadata: snapshot[:metadata].to_h,
        provenance: baseline_provenance
      }.compact
    end

    def normalized_status(item)
      return "dropped" if item.respond_to?(:dropped?) && item.dropped?
      return "completed" if item.completed?

      "open"
    end

    def parent_field(item)
      parent_item_id = item.try(:parent_item_id)
      return { external_id: nil, item_key: nil } unless parent_item_id

      parent = Base::SyncItem.find_by(id: parent_item_id)
      return { external_id: nil, item_key: nil } unless parent&.external_id.present?

      {
        external_id: parent.external_id,
        item_key: parent.item_key
      }
    end

    def sync_collection_field(item)
      return unless item.sync_collection_id

      collection = item.sync_collection
      return unless collection

      {
        sync_collection_id: collection.id,
        title: collection.title
      }
    end

    def baseline_provenance
      {
        detected_by: PROVENANCE_DETECTED_BY,
        backfilled_at: now.utc.iso8601(6)
      }
    end

    def iso_timestamp(value)
      value&.utc&.iso8601(6)
    end

    def enqueue_or_replay(_item, payload, context)
      Outbox::IsolatedWrite.call("baseline item snapshot for #{context[:service_instance]}:#{context[:external_id]}") do
        OutboxEntry.enqueue(record_kind: :item, payload:, **context)
      end
    end

    # The diff baseline advances only after the outbox row is enqueued.
    # If the write fails, IsolatedWrite returns nil and the next sync
    # re-detects the baseline as a fresh first observation (at-least-once).
    def advance_baseline(item)
      snapshot = Base::SnapshotSerializer.call(item).deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end

      item.update_column(:last_snapshot, snapshot)
    end
  end
end
