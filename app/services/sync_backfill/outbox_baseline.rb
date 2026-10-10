# frozen_string_literal: true

module SyncBackfill
  # Backfills baseline publication rows into the local outbox for existing
  # TaskBridge data (RDR #215 "Migration and Backfill Implications", issue
  # #222) so TaskBridge Web can start from the known current state and only
  # treat later diffs as change history.
  #
  # What it emits:
  # - one `item` snapshot row per existing sync item, marked as a baseline
  #   (`provenance.detected_by: "backfill"` plus `backfilled_at`) instead of
  #   pretending to be historical change events: the backfill writes no
  #   `snapshot_seen` observation rows and no `sync_run` rows;
  # - `mapping` rows for existing SyncCollection memberships, but only for
  #   confirmed (sync-id/created-by-sync) and inferred (title-derived)
  #   mappings. Low-confidence (`tentative`) memberships are withheld from
  #   publication and listed in the summary for manual cleanup instead.
  #
  # The backfill never mutates external source systems: it reads local rows
  # and writes local outbox rows only. It is idempotent: every row's
  # idempotency key is derived from stable observation timestamps (set by
  # SyncBackfill::SourceProvenance, which a real run invokes first), so
  # re-running leaves already-backfilled rows untouched.
  class OutboxBaseline
    DETECTED_BY = "backfill"
    PUBLISHED_CONFIDENCES = %w[confirmed inferred].freeze

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
      @summary = Summary.new(dry_run:)
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run?
      backfill_item_snapshots
      backfill_mappings
      summary.to_h
    end

    private

    attr_reader :now, :summary

    def dry_run?
      @dry_run
    end

    def backfill_item_snapshots
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary.skip_item
        elsif snapshot_enqueued?(item)
          summary.record_item(service_type_of(item))
        else
          summary.drop_item
        end
      end
    end

    # A dry run enqueues nothing by design; a real run reports a dropped
    # write when the isolated enqueue failed so a rerun can re-detect it.
    def snapshot_enqueued?(item)
      dry_run? || enqueue_item_snapshot(item)
    end

    def enqueue_item_snapshot(item)
      identity = Outbox::SourceIdentity.for(item)
      Outbox::IsolatedWrite.call("baseline snapshot for #{item.item_key}") do
        OutboxEntry.enqueue(
          record_kind: :item,
          payload: item_payload(item),
          service_type: identity[:service_type],
          service_instance: identity[:service_instance],
          external_id: identity[:external_id],
          sync_collection_id: item.sync_collection_id,
          source_updated_at: item.source_updated_at || item.last_modified,
          observed_at: item_observed_at(item)
        )
      end
    end

    # The published snapshot form matches live observation rows
    # (Outbox::ObservationEmitter#published_snapshot): timestamps render as
    # ISO 8601 UTC so JSON round-trips keep microsecond precision.
    def item_payload(item)
      published_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        sync_collection: sync_collection_payload(item),
        provenance: item_provenance(item)
      ).compact
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def sync_collection_payload(item)
      return unless item.sync_collection

      {
        sync_collection_id: item.sync_collection_id,
        title: item.sync_collection.title,
        membership_role: Outbox::MappingEmitter::MEMBERSHIP_ROLE
      }
    end

    def item_provenance(item)
      backfill_provenance.merge(first_observed_at: iso_timestamp(item.first_observed_at))
    end

    def backfill_provenance
      {
        detected_by: DETECTED_BY,
        backfilled_at: iso_timestamp(now),
        baseline: true
      }
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        members, incomplete = collection.sync_items.partition { |item| item.external_id.present? }
        summary.skip_mappings(incomplete.size)
        record_mappings(collection, members)
      end
    end

    def record_mappings(collection, members)
      confidence = translated_confidence_for(collection)
      if confidence.nil?
        summary.skip_mappings(members.size)
      elsif PUBLISHED_CONFIDENCES.include?(confidence)
        publish_mappings(collection, members, confidence)
      else
        summary.withhold_mappings(members.size, confidence)
      end
    end

    def publish_mappings(collection, members, confidence)
      return summary.record_mappings(members.size, confidence) if dry_run?

      rows = Outbox::MappingEmitter.emit_for_members(
        collection,
        members:,
        observed_at: mapping_observed_at(collection),
        provenance_extras: backfill_provenance
      )
      summary.record_mappings(rows.size, confidence)
      summary.drop_mappings(members.size - rows.size)
    end

    def translated_confidence_for(collection)
      confidence = collection.mapping_confidence
      confidence = inferred_confidence_for(collection) if confidence.blank? && dry_run?
      return if confidence.blank?

      Outbox::MappingEmitter.confidence_for(confidence)
    end

    # A dry run does not invoke the provenance backfill (it writes), so
    # preview the confidence it would assign by running the same pure
    # inference over the collection's items.
    def inferred_confidence_for(collection)
      SyncBackfill::SourceProvenance.inferred_provenance_for(collection)[:confidence]
    end

    def item_observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at || now
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || now
    end

    def service_type_of(item)
      Base::Service.service_identifier_for(item.provider)
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
