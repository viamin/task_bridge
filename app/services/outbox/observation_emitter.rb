# frozen_string_literal: true

module Outbox
  # Emits normalized `observation` rows (RDR #215) into the local outbox by
  # diffing the previous normalized snapshot against the newly observed one
  # (#219). Emission is bookkeeping only: it runs after the item has already
  # been observed and never changes sync semantics. The diff baseline is
  # advanced only once every row is enqueued, so a publication hiccup can
  # re-detect (at-least-once) but never silently swallow a transition.
  # Write failures (e.g. a transient SQLite lock) are isolated, retried,
  # and reported via Outbox::IsolatedWrite so they never propagate into
  # the sync flow.
  class ObservationEmitter
    SNAPSHOT_SEEN = "snapshot_seen"
    SOURCE_CHANGED = "source_changed"
    SYNC_COMPARE = "sync_compare"
    DEFAULT_DISCOVERY_DETECTED_BY = "source_refresh"

    def self.emit_for_item(item, previous_snapshot: nil, observed_at: nil,
                           discovery_detected_by: DEFAULT_DISCOVERY_DETECTED_BY)
      Outbox::IsolatedWrite.call("observation for #{item.item_key}") do
        new(item, previous_snapshot:, observed_at:, discovery_detected_by:).emit
      end
    end

    def initialize(item, previous_snapshot:, observed_at:, discovery_detected_by:)
      @item = item
      @previous_snapshot = previous_snapshot
      @observed_at = observed_at || item.last_observed_at || Time.current
      @discovery_detected_by = discovery_detected_by
    end

    def emit
      return [] if item.options[:pretend] || !item.persisted? || item.external_id.blank?

      rows = observation_rows
      rows.each_with_index do |payload, index|
        enqueue(payload, sequence: rows.many? ? index + 1 : nil)
      end
      # Rows is empty exactly when the new snapshot is diff-equivalent to
      # the stored baseline (SnapshotDiff.transitions found nothing), so
      # skipping advance_baseline here avoids a redundant UPDATE on every
      # unchanged hourly refresh.
      advance_baseline if rows.any?
      rows
    end

    private

    attr_reader :item, :previous_snapshot, :observed_at, :discovery_detected_by

    def observation_rows
      if previous_snapshot.blank?
        [observation_payload(event_type: SNAPSHOT_SEEN, detected_by: discovery_detected_by)]
      else
        SnapshotDiff.transitions(previous_snapshot, published_snapshot).map do |transition|
          observation_payload(event_type: SOURCE_CHANGED, detected_by: SYNC_COMPARE, change: transition)
        end
      end
    end

    def observation_payload(event_type:, detected_by:, change: nil)
      payload = {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        event_type:,
        observed_at: iso_timestamp(observed_at),
        item_key: item.item_key,
        source: source_identity,
        source_created_at: iso_timestamp(item.source_created_at),
        source_updated_at: iso_timestamp(item.source_updated_at || item.last_modified),
        completed_at: iso_timestamp(item.completed_at || item.completed_on),
        provenance: provenance(detected_by)
      }
      payload[:change] = change if change
      payload[:snapshot] = published_snapshot if event_type == SNAPSHOT_SEEN
      payload
    end

    def provenance(detected_by)
      { detected_by: }.tap do |provenance|
        started_at = item.options[:sync_started_at]
        provenance[:sync_run_id] = Outbox::SyncRunId.for(item.service_name, at: started_at) if started_at.present?
      end
    end

    def enqueue(payload, sequence:)
      context = {
        service_type: source_identity[:service_type],
        service_instance: source_identity[:service_instance],
        external_id: source_identity[:external_id],
        event_type: payload[:event_type],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
      context[:sequence] = sequence if sequence
      OutboxEntry.enqueue(record_kind: :observation, payload:, **context)
    end

    def advance_baseline
      item.update_column(:last_snapshot, published_snapshot)
    end

    # The published and stored form of the snapshot: identical to
    # normalized_snapshot but with timestamps rendered as ISO 8601 UTC so
    # JSON round-trips keep microsecond precision and stay diff-stable.
    def published_snapshot
      @published_snapshot ||= item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def source_identity
      @source_identity ||= Outbox::SourceIdentity.for(item)
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
