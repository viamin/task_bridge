# frozen_string_literal: true

module Outbox
  # Backfills the local outbox with baseline rows for data that already
  # existed before publication was enabled (RDR #215 "Migration and Backfill
  # Implications", issue #222), so TaskBridge Web starts from the known
  # current state and only later diffs become change history.
  #
  # What it writes:
  # - one `item` snapshot per existing sync item, marked as a baseline
  #   rather than a historical change event through provenance
  #   (detected_by: "backfill" plus backfilled_at) — no `snapshot_seen`
  #   observation rows;
  # - one `mapping` row per publishable sync_collection membership.
  #   Low-confidence and never-classified mappings are withheld from
  #   publication and only counted in the summary (the RDR #215 Open
  #   Questions default, confirmed for #222; the product owner may
  #   revisit title/low-confidence handling later);
  # - no `sync_run` rows: sync_service_states holds no reliable per-run
  #   start/end timestamps, and the RDR only allows backfilled sync-run
  #   summaries where reliable timestamps exist.
  #
  # Idempotency: every row's idempotency key embeds an observed_at derived
  # deterministically from stored data (last observation or record
  # timestamps), so re-running returns the stored rows instead of
  # duplicating facts. The backfill only reads and writes local tables —
  # it never contacts external source systems.
  class BaselineBackfill
    DETECTED_BY = "backfill"
    # Internal confidences that must not reach TaskBridge Web from the
    # backfill. `nil` (never classified) is withheld alongside low.
    WITHHELD_CONFIDENCES = [nil, "low"].freeze
    SERVICE_COUNTS = { total: 0, enqueued: 0, existing: 0, skipped: 0 }.freeze

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run: false, now: Time.current)
      @dry_run = dry_run
      @now = now
      @items = { total: 0, enqueued: 0, existing: 0, skipped: 0,
                 by_service: {}, skipped_reasons: Hash.new(0) }
      @mappings = { collections: 0, memberships: 0, enqueued: 0, existing: 0,
                    withheld: 0, skipped: 0, by_confidence: Hash.new(0) }
    end

    attr_reader :dry_run, :now

    def run!
      # Identity/mapping provenance backfill (#218) is a prerequisite: it
      # stamps last_observed_at and mapping confidence, which key and gate
      # the rows below. It is itself idempotent, so it is simply rerun.
      SyncBackfill::SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      { dry_run:, items: @items, mappings: @mappings }
    end

    private

    def backfill_items
      Base::SyncItem.find_each do |item|
        service = item.service_name
        if item.external_id.blank?
          record_item(service, :skipped, reason: "missing_external_id")
          next
        end

        record_item(service, emit_item(item))
      rescue StandardError => e
        # One unserializable legacy row must not block the whole baseline:
        # report it, count it, and keep going (the backfill is a migration
        # boundary, not a sync flow). Reruns retry the skipped rows.
        warn "[Outbox] skipping #{item.item_key} during backfill (#{e.class}: #{e.message})"
        record_item(service, :skipped, reason: "serialization_failed")
      end
    end

    def emit_item(item)
      observed_at = item.last_observed_at || item.updated_at || item.created_at
      identity = Outbox::SourceIdentity.for(item)
      outcome_for(
        :item,
        item_payload(item, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def item_payload(item, observed_at)
      # The published snapshot form (mirrors Outbox::ObservationEmitter):
      # the normalized snapshot with timestamps rendered as ISO 8601 UTC,
      # minus the local `version` field the contract replaces with
      # contract_version, plus the baseline markers. Extra payload fields
      # are safe: version 1 consumers must ignore unknown fields.
      published_snapshot(item)
        .except(:version)
        .merge(
          contract_version: OutboxEntry::PAYLOAD_VERSION,
          observed_at: iso_timestamp(observed_at),
          provenance: { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(now) }
        )
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        @mappings[:collections] += 1
        collection.sync_items.each { |member| backfill_membership(collection, member) }
      end
    end

    def backfill_membership(collection, member)
      @mappings[:memberships] += 1
      confidence = collection.mapping_confidence.presence || "unknown"
      @mappings[:by_confidence][confidence] += 1
      return @mappings[:withheld] += 1 if WITHHELD_CONFIDENCES.include?(collection.mapping_confidence)
      return @mappings[:skipped] += 1 if member.external_id.blank?

      @mappings[emit_membership(collection, member)] += 1
    end

    def emit_membership(collection, member)
      observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at
      identity = Outbox::SourceIdentity.for(member)
      outcome_for(
        :mapping,
        mapping_payload(collection, member, identity, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: collection.id,
        observed_at:
      )
    end

    def mapping_payload(collection, member, identity, observed_at)
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        mapping_type: Outbox::MappingEmitter::MAPPING_TYPE,
        observed_at: iso_timestamp(observed_at),
        sync_collection: { sync_collection_id: collection.id, title: collection.title },
        member: identity.merge(item_key: member.item_key),
        membership_role: Outbox::MappingEmitter::MEMBERSHIP_ROLE,
        mapping_confidence: Outbox::MappingEmitter::CONFIDENCE.fetch(collection.mapping_confidence, collection.mapping_confidence),
        mapping_source: Outbox::MappingEmitter::SOURCE.fetch(collection.mapping_method, collection.mapping_method),
        provenance: {
          method: collection.mapping_method,
          confidence: collection.mapping_confidence,
          metadata: collection.mapping_metadata,
          detected_by: DETECTED_BY,
          backfilled_at: iso_timestamp(now)
        }
      }
    end

    # Computes the deterministic idempotency key up front (the same key
    # OutboxEntry.enqueue would build) so dry runs can report whether a
    # real run would create or reuse each row without writing anything.
    def outcome_for(record_kind, payload, context)
      key = Outbox::IdempotencyKey.for(record_kind:, **context)
      return OutboxEntry.exists?(idempotency_key: key) ? :existing : :enqueued if dry_run

      row = OutboxEntry.enqueue(record_kind:, payload:, idempotency_key: key, **context)
      # A nil row only happens when global options run in pretend mode,
      # where enqueue is a strict no-op: nothing is created to count.
      row&.previously_new_record? ? :enqueued : :existing
    end

    def record_item(service, outcome, reason: nil)
      @items[:total] += 1
      @items[outcome] += 1
      counts = (@items[:by_service][service] ||= SERVICE_COUNTS.dup)
      counts[:total] += 1
      counts[outcome] += 1
      @items[:skipped_reasons][reason] += 1 if reason
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
