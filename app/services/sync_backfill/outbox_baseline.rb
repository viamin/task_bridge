# frozen_string_literal: true

module SyncBackfill
  # Seeds the local outbox with the baseline TaskBridge Web needs before
  # publication is enabled (#222; RDR #215 "Migration and Backfill
  # Implications"): one current-state `item` snapshot per existing sync
  # item and one `mapping` row per SyncCollection membership.
  #
  # Baseline rows are initial observations of current state, not
  # historical change events: every payload carries
  # `provenance.detected_by: "backfill"` and a `backfilled_at` timestamp.
  # `backfilled_at` equals the row's deterministic `observed_at` (the
  # item's `last_observed_at`, or the collection's
  # `mapping_last_observed_at`) so a rerun can never resubmit the same
  # idempotency key with a different payload — even after delivered rows
  # are pruned and the row is re-created.
  #
  # Mapping policy (clarified decision for #222, resolving RDR #215's
  # open question): `high` confidence publishes as `confirmed` and
  # `medium` as `inferred`; `low`-confidence memberships are withheld
  # from publication and stay reviewable through the dry-run summary
  # counts by confidence. The item snapshots of withheld members omit
  # their `sync_collection` block so a withheld mapping never leaks
  # through a different row kind.
  #
  # The backfill only reads local tables and writes outbox rows; it never
  # contacts an external source system and never mutates `sync_items` or
  # `sync_collections`. It assumes the provenance backfill
  # (`SyncBackfill::SourceProvenance`) has already populated source
  # identity and mapping metadata — the rake task enforces that order.
  class OutboxBaseline
    DETECTED_BY = "backfill"
    # Internal SyncCollection#mapping_confidence → contract vocabulary.
    # Deliberately different from Outbox::MappingEmitter's live mapping:
    # the clarified #222 decision publishes `medium` as `inferred`, and
    # `low` is withheld entirely rather than published as `tentative`.
    CONFIDENCE = { "high" => "confirmed", "medium" => "inferred" }.freeze

    WITHHELD_LOW_CONFIDENCE = :withheld_low_confidence
    SKIPPED_INCOMPLETE = :skipped_incomplete
    EXECUTED_OUTCOMES = %i[created already_present].freeze

    def self.run!
      new.run!
    end

    def self.preview
      new.preview
    end

    def run!
      each_item { |item, row| tally_item(item, enqueue(row)) }
      each_membership { |collection, member, row| tally_membership(collection, member, enqueue(row)) }
      summary
    end

    # The same plan as run! without writing any outbox row: the summary an
    # operator reviews (counts by service and confidence, withheld
    # low-confidence memberships, skipped incomplete records) before the
    # real run.
    def preview
      each_item { |item, row| tally_item(item, planned_reason(row)) }
      each_membership { |collection, member, row| tally_membership(collection, member, planned_reason(row)) }
      summary.merge(dry_run: true)
    end

    private

    def each_item
      Base::SyncItem.find_each { |item| yield item, item_row(item) }
    end

    def each_membership
      # includes avoids one query per collection while iterating members.
      SyncCollection.includes(:sync_items).find_each do |collection|
        collection.sync_items.each { |member| yield collection, member, membership_row(collection, member) }
      end
    end

    # Row plans are OutboxEntry.enqueue context hashes, or a Symbol skip
    # reason. observed_at is deterministic per record so idempotency keys
    # are stable across reruns.
    def item_row(item)
      identity = Outbox::SourceIdentity.for(item)
      return SKIPPED_INCOMPLETE if identity[:external_id].blank?

      observed_at = item.last_observed_at || item.updated_at || item.created_at
      {
        record_kind: :item,
        payload: item_payload(item, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      }
    end

    def membership_row(collection, member)
      return WITHHELD_LOW_CONFIDENCE if collection.mapping_confidence == "low"
      return SKIPPED_INCOMPLETE unless CONFIDENCE.key?(collection.mapping_confidence)

      identity = Outbox::SourceIdentity.for(member)
      return SKIPPED_INCOMPLETE if identity[:external_id].blank?

      observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at
      {
        record_kind: :mapping,
        payload: mapping_payload(collection, member, identity, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: collection.id,
        observed_at:
      }
    end

    def enqueue(row)
      return row unless row.is_a?(Hash)

      entry = OutboxEntry.enqueue(**row)
      # A nil entry means the run is in --pretend mode: no row was
      # written, so the record is honestly counted as skipped.
      return SKIPPED_INCOMPLETE if entry.nil?

      entry.previously_new_record? ? :created : :already_present
    end

    def planned_reason(row)
      row.is_a?(Hash) ? :planned : row
    end

    def item_payload(item, observed_at)
      snapshot = published_snapshot(item)
      payload = {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        **snapshot.except(:metadata),
        observed_at: iso_timestamp(observed_at),
        source_metadata: snapshot[:metadata],
        backfilled_at: iso_timestamp(observed_at),
        provenance: { detected_by: DETECTED_BY }
      }
      publishable_collection = publishable_collection_for(item)
      payload[:sync_collection] = sync_collection_payload(publishable_collection) if publishable_collection
      payload
    end

    def mapping_payload(collection, member, identity, observed_at)
      Outbox::MappingEmitter.payload_for(collection, member, identity, observed_at).then do |payload|
        payload.merge(
          mapping_confidence: CONFIDENCE.fetch(collection.mapping_confidence),
          backfilled_at: iso_timestamp(observed_at),
          provenance: payload.fetch(:provenance).merge(detected_by: DETECTED_BY, backfilled_at: iso_timestamp(observed_at))
        )
      end
    end

    def sync_collection_payload(collection)
      {
        sync_collection_id: collection.id,
        membership_role: Outbox::MappingEmitter::MEMBERSHIP_ROLE,
        mapping_confidence: CONFIDENCE.fetch(collection.mapping_confidence),
        mapping_source: Outbox::MappingEmitter::SOURCE.fetch(collection.mapping_method, collection.mapping_method)
      }
    end

    def publishable_collection_for(item)
      publishable_collections[item.sync_collection_id]
    end

    # One query, memoized for the run: which collections carry a
    # publishable (high/medium) mapping confidence.
    def publishable_collections
      @publishable_collections ||= SyncCollection.where(mapping_confidence: CONFIDENCE.keys).index_by(&:id)
    end

    # The published snapshot form, identical to the live emitter's: the
    # normalized snapshot with timestamps rendered as ISO 8601 UTC.
    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def tally_item(item, outcome)
      items = summary[:items]
      items[:total] += 1
      if outcome == :planned || EXECUTED_OUTCOMES.include?(outcome)
        items[outcome] += 1 if EXECUTED_OUTCOMES.include?(outcome)
        items[:planned] += 1
        items[:by_service][service_type_of(item)] += 1
      else
        items[:skipped] += 1
      end
    end

    def tally_membership(collection, member, outcome)
      mappings = summary[:mappings]
      mappings[:memberships] += 1
      if outcome == WITHHELD_LOW_CONFIDENCE
        mappings[:withheld] += 1
      elsif outcome == :planned || EXECUTED_OUTCOMES.include?(outcome)
        mappings[outcome] += 1 if EXECUTED_OUTCOMES.include?(outcome)
        mappings[:planned] += 1
        mappings[:by_confidence][CONFIDENCE.fetch(collection.mapping_confidence)] += 1
        mappings[:by_service][service_type_of(member)] += 1
      else
        mappings[:skipped] += 1
      end
    end

    def service_type_of(item)
      Outbox::SourceIdentity.for(item)[:service_type]
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end

    def summary
      @summary ||= {
        items: { total: 0, planned: 0, created: 0, already_present: 0, skipped: 0, by_service: Hash.new(0) },
        mappings: { memberships: 0, planned: 0, created: 0, already_present: 0, withheld: 0, skipped: 0,
                    by_confidence: Hash.new(0), by_service: Hash.new(0) }
      }
    end
  end
end
