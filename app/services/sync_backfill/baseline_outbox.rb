# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox with baseline rows for already-synchronized data
  # (issue #222): one current-state `item` snapshot per existing sync_items
  # row and one `mapping` row per existing SyncCollection membership, so
  # TaskBridge Web starts from known current state and only later diffs
  # read as change history (RDR #215 "Migration and Backfill
  # Implications").
  #
  # Baseline rows are marked as initial observations rather than
  # historical change events: item payloads carry
  # `provenance.detected_by: "backfill"` plus a `backfilled_at` timestamp,
  # and no `snapshot_seen` observation or sync-run rows are emitted —
  # sync_service_states has no reliable per-run timestamps, and live sync
  # runs (#219-#221) publish those going forward.
  #
  # Idempotent by construction: SyncBackfill::SourceProvenance first
  # backfills identity/provenance columns, rows carry deterministic
  # idempotency keys derived from stable observed_at timestamps
  # (last_observed_at / mapping_last_observed_at), and identities that
  # already have an outbox row are skipped — so reruns, including after
  # live syncs, enqueue nothing new. The backfill only writes local rows;
  # external source systems are never contacted.
  #
  # Low-confidence mapping provenance (`mapping_confidence: "low"`,
  # contract `tentative`) is withheld from publication per RDR #215's
  # default (#222 clarified decision); those memberships stay identifiable
  # through the returned summary's counts by confidence. `high` maps to
  # `confirmed` and `medium` to `inferred` (Outbox::MappingEmitter).
  class BaselineOutbox
    DETECTED_BY = "backfill"
    # Only memberships TaskBridge can state with at least title-match
    # evidence are published; low-confidence and unknown provenance are
    # withheld for later manual cleanup or Web-side review.
    PUBLISHED_CONFIDENCES = %w[high medium].freeze
    SNAPSHOT_FIELDS = %i[
      item_key entity_type title status is_deleted completed_at notes_digest
      source_created_at source_updated_at due_at flagged tags parent_item_id
    ].freeze

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
      @summary = Summary.new(dry_run:)
    end

    # Returns a Summary (counts by service and mapping confidence, plus
    # skipped/incomplete records) the rake task renders.
    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run?
      backfill_item_snapshots
      backfill_mappings
      summary
    end

    private

    attr_reader :now, :summary

    def dry_run?
      @dry_run
    end

    def backfill_item_snapshots
      Base::SyncItem.find_each { |item| backfill_item(item) }
    end

    def backfill_item(item)
      identity = Outbox::SourceIdentity.for(item)
      bucket = summary.item_bucket(identity[:service_type])
      bucket[:total] += 1
      return summary.record_incomplete_item(item, bucket) if identity[:external_id].blank?
      return bucket[:already_enqueued] += 1 if item_row_exists?(identity)

      observed_at = item_observed_at(item)
      snapshot = published_snapshot(item)
      unless dry_run?
        enqueue_item_snapshot(item, identity, snapshot, observed_at)
        seed_diff_baseline(item, snapshot)
      end
      bucket[:enqueued] += 1
    end

    def enqueue_item_snapshot(item, identity, snapshot, observed_at)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(identity, snapshot, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        observed_at:,
        source_updated_at: item.source_updated_at || item.last_modified
      )
    end

    # The RDR #215 item snapshot shape, built from the shared normalized
    # snapshot so backfilled rows cannot drift from live observation
    # payloads. Extra fields are safe: version 1 consumers ignore unknown
    # fields.
    def item_payload(identity, snapshot, observed_at)
      payload = {
        **snapshot.slice(*SNAPSHOT_FIELDS),
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        started_at: snapshot[:start_at] || snapshot[:start_date],
        source: identity,
        source_metadata: snapshot[:metadata],
        provenance: { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(now) }
      }
      collection = collection_block(item_collection(snapshot[:sync_collection_id]))
      payload[:sync_collection] = collection if collection
      payload
    end

    # Membership facts stay out of item snapshots when the mapping is
    # withheld: low-confidence memberships are not published in any form
    # (#222 clarified decision).
    def collection_block(collection)
      return unless collection && PUBLISHED_CONFIDENCES.include?(collection.mapping_confidence)

      {
        sync_collection_id: collection.id,
        membership_role: Outbox::MappingEmitter::MEMBERSHIP_ROLE,
        mapping_confidence: Outbox::MappingEmitter::CONFIDENCE.fetch(collection.mapping_confidence, collection.mapping_confidence),
        mapping_source: Outbox::MappingEmitter::SOURCE.fetch(collection.mapping_method, collection.mapping_method)
      }
    end

    def item_collection(sync_collection_id)
      return if sync_collection_id.blank?

      collections_by_id[sync_collection_id]
    end

    def collections_by_id
      @collections_by_id ||= SyncCollection.all.index_by(&:id)
    end

    # Seeds the live diff baseline (#219) so the first refresh after the
    # backfill only publishes real changes instead of rediscovering every
    # item. Stored in the exact shape Outbox::ObservationEmitter uses.
    def seed_diff_baseline(item, snapshot)
      return unless item.last_snapshot.blank?

      item.update_column(:last_snapshot, snapshot)
    end

    # Stable across reruns (never Time.current): after the provenance
    # backfill last_observed_at is pinned, and reruns skip identities that
    # already have an outbox row anyway.
    def item_observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at || now
    end

    def item_row_exists?(identity)
      existing_item_identities.include?(identity.values_at(:service_type, :service_instance, :external_id))
    end

    def existing_item_identities
      @existing_item_identities ||= OutboxEntry.where(record_kind: "item")
                                               .pluck(:service_type, :service_instance, :external_id).to_set
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
    end

    def backfill_collection(collection)
      bucket = summary.mapping_bucket(published_confidence_for(collection))
      publishable = PUBLISHED_CONFIDENCES.include?(collection.mapping_confidence)
      eligible = collection.sync_items.each_with_object([]) do |member, pending|
        identity = Outbox::SourceIdentity.for(member)
        bucket[:members] += 1
        if identity[:external_id].blank?
          bucket[:incomplete] += 1
        elsif !publishable
          bucket[:withheld] += 1
        elsif membership_row_exists?(collection, identity)
          bucket[:already_enqueued] += 1
        else
          pending << member
        end
      end
      bucket[:enqueued] += eligible.length
      return if dry_run? || eligible.empty?

      Outbox::MappingEmitter.emit_for_members(collection, members: eligible,
                                                          observed_at: mapping_observed_at(collection))
    end

    # The contract confidence bucket the summary reports: `high` ->
    # `confirmed`, `medium` -> `inferred`, `low` -> `tentative`, and
    # anything unrecognized (including nil) -> `unknown`.
    def published_confidence_for(collection)
      Outbox::MappingEmitter::CONFIDENCE.fetch(collection.mapping_confidence, "unknown")
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || now
    end

    def membership_row_exists?(collection, identity)
      existing_memberships.include?(
        [collection.id, *identity.values_at(:service_type, :service_instance, :external_id)]
      )
    end

    def existing_memberships
      @existing_memberships ||= OutboxEntry.where(record_kind: "mapping")
                                           .pluck(:sync_collection_id, :service_type, :service_instance,
                                                  :external_id).to_set
    end

    # The stored and published form of the snapshot: identical to
    # normalized_snapshot but with timestamps rendered as ISO 8601 UTC so
    # JSON round-trips keep microsecond precision and stay diff-stable.
    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
