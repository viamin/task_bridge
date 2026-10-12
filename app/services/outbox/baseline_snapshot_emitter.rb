# frozen_string_literal: true

module Outbox
  # Seeds the outbox with a current-state row for data that predates the
  # observation pipeline. It intentionally emits no `snapshot_seen` event:
  # the row establishes state, not a claim about historical change.
  class BaselineSnapshotEmitter
    DETECTED_BY = "backfill"

    def self.emit_for(item, observed_at:, dry_run: false)
      new(item, observed_at:, dry_run:).emit
    end

    def initialize(item, observed_at:, dry_run:)
      @item = item
      @observed_at = observed_at
      @dry_run = dry_run
    end

    def emit
      return :incomplete if item.external_id.blank?
      return :preview if dry_run

      OutboxEntry.enqueue(record_kind: :item, payload:, **context)
      item.update_column(:last_snapshot, serialized_snapshot) if item.last_snapshot.blank?
      :enqueued
    end

    private

    attr_reader :item, :observed_at, :dry_run

    def payload
      serialized_snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        item_key: item_key,
        observed_at: timestamp(observed_at),
        source: identity,
        provenance: { detected_by: DETECTED_BY, backfilled_at: timestamp(observed_at) }
      )
    end

    def context
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
    end

    def serialized_snapshot
      @serialized_snapshot ||= item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? timestamp(value) : value
      end
    end

    def identity
      @identity ||= Outbox::SourceIdentity.for(item)
    end

    def item_key
      [identity[:service_instance], identity[:external_id]].join(":")
    end

    def timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
