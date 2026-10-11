# frozen_string_literal: true

module SyncBackfill
  # Backfills the TaskBridge Web baseline (issue #222): turns existing
  # `sync_items` and `sync_collections` memberships into the outbox rows
  # RDR #215 needs before publication is enabled, so TaskBridge Web can
  # start from the known current state and treat only later diffs as change
  # history.
  #
  # What the baseline contains:
  # - one `item` current-state snapshot per existing sync item, marked as a
  #   baseline observation (`provenance.detected_by: "backfill"` plus a
  #   `backfilled_at` timestamp) rather than a historical change event —
  #   the backfill never emits `snapshot_seen` observation rows;
  # - one `mapping` row per existing `sync_collection` membership, withheld
  #   when the collection's mapping confidence is low (Outbox::MappingEmitter
  #   policy): low-confidence memberships stay identifiable in this
  #   summary for manual cleanup;
  # - no `sync_run` rows: `sync_service_states` has no reliable per-run
  #   started_at/finished_at, and live sync runs publish them going forward.
  #
  # Idempotency: reruns skip identities that already have their baseline row
  # and use deterministic idempotency keys derived from stable per-record
  # timestamps (`last_observed_at` / `mapping_last_observed_at`), so running
  # the backfill repeatedly never duplicates facts. The backfill only reads
  # existing sync data and writes the local outbox; external source systems
  # are never touched.
  class Baseline
    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run: false)
      @dry_run = dry_run
      @backfilled_at = Time.current
      @item_identities = existing_item_identities
      @mapping_identities = existing_mapping_identities
      @summary = {
        dry_run:,
        items: { enqueued: 0, already_backfilled: 0, incomplete: 0 },
        items_by_service: {},
        mappings: { memberships: 0, enqueued: 0, already_backfilled: 0, withheld_low_confidence: 0, incomplete: 0 },
        mappings_by_confidence: {},
        withheld_low_confidence_collections: []
      }
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      backfill_item_snapshots
      backfill_mapping_rows
      summary
    end

    private

    attr_reader :dry_run, :backfilled_at, :item_identities, :mapping_identities, :summary

    def backfill_item_snapshots
      Base::SyncItem.find_each do |item|
        identity = Outbox::SourceIdentity.for(item)
        if identity[:external_id].blank? || item.title.blank?
          summary[:items][:incomplete] += 1
          next
        end
        if item_identities.include?(item_identity_key(identity))
          summary[:items][:already_backfilled] += 1
          next
        end

        enqueue_item_snapshot(item, identity)
        summary[:items][:enqueued] += 1
        bump(summary[:items_by_service], identity[:service_type])
      end
    end

    def backfill_mapping_rows
      SyncCollection.includes(:sync_items).find_each do |collection|
        eligible, ineligible = collection.sync_items.to_a.partition { |member| member.external_id.present? }
        summary[:mappings][:memberships] += eligible.length
        summary[:mappings][:incomplete] += ineligible.length

        provenance = resolved_provenance(collection)
        if provenance[:confidence] == Outbox::MappingEmitter::WITHHELD_INTERNAL_CONFIDENCE
          withhold(collection, eligible.length, provenance[:method])
          next
        end

        eligible.each do |member|
          identity = Outbox::SourceIdentity.for(member)
          if mapping_identities.include?(mapping_identity_key(collection, identity))
            summary[:mappings][:already_backfilled] += 1
            next
          end

          enqueue_mapping_row(collection, member)
          summary[:mappings][:enqueued] += 1
          bump(summary[:mappings_by_confidence], Outbox::MappingEmitter.contract_confidence_for(provenance[:confidence]))
        end
      end
    end

    def enqueue_item_snapshot(item, identity)
      return if dry_run

      observed_at = item_observed_at(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: ItemPayload.for(item, identity, observed_at:, backfilled_at:),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def enqueue_mapping_row(collection, member)
      return if dry_run

      Outbox::MappingEmitter.emit_for_members(collection, members: [member], observed_at: mapping_observed_at(collection))
    end

    # Provenance for the publication decision. After the (idempotent)
    # provenance backfill every collection carries persisted provenance; the
    # in-memory inference keeps the dry run faithful without writing.
    def resolved_provenance(collection)
      return { method: collection.mapping_method, confidence: collection.mapping_confidence } if collection.mapping_method.present?

      SyncBackfill::SourceProvenance.inferred_provenance_for(collection)
    end

    def withhold(collection, member_count, method)
      summary[:mappings][:withheld_low_confidence] += member_count
      summary[:withheld_low_confidence_collections] << {
        sync_collection_id: collection.id,
        title: collection.title,
        members: member_count,
        mapping_method: method
      }
    end

    # Stable per-record timestamps keep idempotency keys deterministic across
    # reruns; the wall-clock backfill time is only metadata (`backfilled_at`).
    def item_observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at || backfilled_at
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || backfilled_at
    end

    def existing_item_identities
      OutboxEntry.where(record_kind: "item")
                 .pluck(:service_type, :service_instance, :external_id)
                 .to_set { |identity| identity.join("\0") }
    end

    def existing_mapping_identities
      OutboxEntry.where(record_kind: "mapping")
                 .pluck(:sync_collection_id, :service_type, :service_instance, :external_id)
                 .to_set { |identity| identity.join("\0") }
    end

    def item_identity_key(identity)
      [identity[:service_type], identity[:service_instance], identity[:external_id]].join("\0")
    end

    def mapping_identity_key(collection, identity)
      [collection.id, identity[:service_type], identity[:service_instance], identity[:external_id]].join("\0")
    end

    def bump(counter, key)
      counter[key] = counter.fetch(key, 0) + 1
    end
  end
end
