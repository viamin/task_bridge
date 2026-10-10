# frozen_string_literal: true

module SyncBackfill
  # Generates the baseline outbox rows that seed TaskBridge Web from
  # existing synchronized data (#222; RDR #215, "Migration and Backfill
  # Implications"): one current-state `item` snapshot per existing
  # sync_items row and `mapping` rows for known SyncCollection
  # memberships. Local provenance is backfilled first
  # (SyncBackfill::SourceProvenance) so identity and mapping evidence
  # exists before anything is queued.
  #
  # Baseline rows are current state, not reconstructed history. Each item
  # payload carries provenance.detected_by "backfill" plus a backfilled_at
  # timestamp instead of a snapshot_seen observation, and no sync_run or
  # deletion rows are written — live sync runs (#219-#221) publish change
  # history going forward.
  #
  # Memberships the local data only supports at low confidence are
  # withheld from publication (decision recorded with #222): they stay
  # reviewable through the dry-run summary until a later sync upgrades
  # their provenance.
  #
  # The run is idempotent and local-only: rows use the same deterministic
  # idempotency keys as the live pipeline, so reruns re-find their own
  # rows instead of duplicating them, no external source system is ever
  # contacted, and publication to TaskBridge Web stays gated behind
  # task_bridge.web.enabled (#221).
  class OutboxBaseline
    DETECTED_BY = "backfill"
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
      @summary = {
        dry_run:,
        items: { total: 0, enqueued: 0, skipped: 0, by_service: {} },
        mappings: { total: 0, enqueued: 0, skipped: 0, withheld: 0,
                    by_service: {}, by_confidence: {}, withheld_memberships: [] }
      }
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run?
      Base::SyncItem.find_each { |item| backfill_item(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
      summary
    end

    private

    attr_reader :now, :summary

    def dry_run?
      @dry_run
    end

    def backfill_item(item)
      service = service_type_of(item)
      summary[:items][:total] += 1
      if item.external_id.blank?
        track(:items, service, :skipped)
        return
      end
      if dry_run?
        track(:items, service, :enqueued)
        return
      end
      return unless Outbox::IsolatedWrite.call("baseline item snapshot for #{item.item_key}") do
        OutboxEntry.enqueue(record_kind: :item, payload: item_payload(item), **item_context(item))
      end

      track(:items, service, :enqueued)
    end

    def backfill_collection(collection)
      provenance = effective_provenance(collection)
      publishable_members = collection.sync_items.filter_map do |member|
        record_membership(collection, member, provenance)
      end
      return if dry_run?

      Outbox::MappingEmitter.emit_for_members(
        collection,
        members: publishable_members,
        observed_at: mapping_observed_at(collection),
        provenance: backfill_provenance
      )
    end

    # Counts one membership by service and confidence, records withheld
    # memberships for the dry-run listing, and returns the member when its
    # mapping row is publishable.
    def record_membership(collection, member, provenance)
      confidence = provenance[:confidence].to_s
      outcome = membership_outcome(member, confidence)
      summary[:mappings][:total] += 1
      count_confidence(confidence)
      track(:mappings, service_type_of(member), outcome)
      record_withheld(collection, member, provenance) if outcome == :withheld && dry_run?
      member if outcome == :enqueued
    end

    def membership_outcome(member, confidence)
      return :skipped if member.external_id.blank?
      return :enqueued if PUBLISHABLE_CONFIDENCES.include?(confidence)

      :withheld
    end

    # In a wet run the provenance backfill has already recorded mapping
    # metadata; the inferred fallback only serves dry-run counts.
    def effective_provenance(collection)
      return { method: collection.mapping_method, confidence: collection.mapping_confidence } if collection.mapping_method.present?

      SyncBackfill::SourceProvenance.inferred_provenance_for(collection).slice(:method, :confidence)
    end

    def item_payload(item)
      Outbox::PublishedSnapshot.for(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(item_observed_at(item)),
        provenance: backfill_provenance
      )
    end

    def item_context(item)
      identity = Outbox::SourceIdentity.for(item)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: item_observed_at(item)
      }
    end

    def item_observed_at(item)
      item.last_observed_at || item.first_observed_at || item.updated_at || now
    end

    # Deterministic across reruns: the mapping backfill records
    # mapping_last_observed_at once, and later runs skip the update.
    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || now
    end

    def backfill_provenance
      { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(now) }
    end

    def record_withheld(collection, member, provenance)
      summary[:mappings][:withheld_memberships] << {
        sync_collection_id: collection.id,
        title: collection.title,
        item_key: member.item_key,
        mapping_method: provenance[:method],
        confidence: provenance[:confidence]
      }
    end

    def track(scope, service, outcome)
      summary[scope][outcome] += 1
      service_bucket(scope, service)[outcome] += 1
    end

    def count_confidence(confidence)
      key = confidence.presence || "unknown"
      summary[:mappings][:by_confidence][key] = summary[:mappings][:by_confidence].fetch(key, 0) + 1
    end

    def service_bucket(scope, service)
      summary[scope][:by_service][service] ||= { enqueued: 0, skipped: 0, withheld: 0 }
    end

    def service_type_of(item)
      Base::Service.service_identifier_for(item.provider)
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
