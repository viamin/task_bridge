# frozen_string_literal: true

module Outbox
  # Backfills the local outbox (#222) so TaskBridge Web can start from the
  # known current state of existing TaskBridge data and only treat later
  # diffs as change history (RDR #215, "Migration and Backfill
  # Implications").
  #
  # The backfill is a read-only pass over local tables that enqueues:
  #   - one baseline `item` snapshot per existing sync item, marked
  #     `provenance.detected_by: "backfill"` plus a `backfilled_at`
  #     timestamp so it can never be mistaken for a historical change
  #     event (no `snapshot_seen` observation rows are written);
  #   - one `mapping` row per SyncCollection membership, translated
  #     `high`->`confirmed` and `medium`->`inferred`; `low`-confidence
  #     memberships are withheld from publication and only counted in the
  #     summary so they stay identifiable for local review;
  #   - no `sync_run` rows (sync_service_states has no reliable per-run
  #     start/end timestamps) and no `observation` rows at all.
  #
  # It never contacts a provider: identities come from the persisted
  # source columns (#216) after the idempotent local provenance backfill
  # (#218) has prepared them. Deterministic idempotency keys — derived
  # from each row's own timestamps, never the wall clock — make reruns
  # safe no-ops. The only writes are outbox rows plus whatever the
  # provenance preparation applies to local TaskBridge tables; external
  # source systems are never mutated.
  class Backfill
    # Contract confidence values the backfill publishes; `tentative`
    # (TaskBridge `low`) is withheld pending product-owner review of
    # title-derived mappings (RDR #215 open question, resolved for the
    # backfill in #222: withhold, and keep the counts in the summary).
    PUBLISHED_MAPPING_CONFIDENCE = %w[confirmed inferred].freeze

    UNKNOWN_SERVICE = "unknown"

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def self.publishable_confidence?(mapping_confidence)
      translated = MappingEmitter::CONFIDENCE.fetch(mapping_confidence, mapping_confidence)

      PUBLISHED_MAPPING_CONFIDENCE.include?(translated)
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
      @summary = Summary.new(dry_run:)
    end

    def run!
      prepare_local_provenance
      backfill_items
      backfill_mappings
      summary.to_h
    end

    private

    attr_reader :now, :summary

    def dry_run?
      @dry_run
    end

    # Ensures identity columns (#216) and collection mapping metadata
    # (#218) exist before identities and confidences are read. That prep
    # is itself an idempotent, local-only backfill; it also runs in
    # dry-run mode so the summary's counts match a subsequent real run.
    def prepare_local_provenance
      SyncBackfill::SourceProvenance.run!
    end

    # Groups items by STI type (SyncBackfill::StiTypes) so a row whose
    # type is missing or no longer resolves is counted as skipped instead
    # of aborting the whole find_each batch during instantiation.
    def backfill_items
      Base::SyncItem.distinct.pluck(:type).each do |type|
        backfill_items_of_type(type)
      end
    end

    def backfill_items_of_type(type)
      scope = Base::SyncItem.where(type: type)
      if SyncBackfill::StiTypes.resolvable_class(type).nil?
        summary.items.count(:skipped, "#{type.presence || 'untyped'}/unresolvable_item_type", scope.count)
        return
      end

      scope.find_each { |item| backfill_item(item) }
    end

    def backfill_item(item)
      return summary.items.count(:skipped, "#{item_service(item)}/missing_external_id") if item.external_id.blank?

      snapshot = ItemSnapshot.new(item, identity: Outbox::SourceIdentity.for(item), backfilled_at: now)
      plan_or_enqueue_item(snapshot)
    rescue StandardError => e
      summary.items.count(:skipped, "#{item_service(item)}/#{unresolvable_reason(e)}")
    end

    def plan_or_enqueue_item(snapshot)
      if dry_run?
        bucket = OutboxEntry.exists?(idempotency_key: snapshot.idempotency_key) ? :already_enqueued : :enqueued
        return summary.items.count(bucket, snapshot.service_type)
      end

      entry = enqueue("backfill item snapshot for #{snapshot.item_key}") do
        OutboxEntry.enqueue(record_kind: :item, payload: snapshot.payload, **snapshot.enqueue_context)
      end
      return summary.items.count(:skipped, "#{snapshot.service_type}/enqueue_failed") if entry.nil?

      summary.items.count(entry.previously_new_record? ? :enqueued : :already_enqueued, snapshot.service_type)
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        members = collection.sync_items.to_a
        if members.empty?
          summary.mappings.count(:skipped, "collection_without_members")
        elsif self.class.publishable_confidence?(collection.mapping_confidence)
          members.each { |member| backfill_membership(collection, member) }
        else
          members.each { summary.mappings.count(:withheld, collection.mapping_confidence.presence || "unknown") }
        end
      end
    end

    def backfill_membership(collection, member)
      return summary.mappings.count(:skipped, "missing_external_id") if member.external_id.blank?

      mapping = MembershipMapping.new(collection, member, identity: Outbox::SourceIdentity.for(member), backfilled_at: now)
      plan_or_enqueue_mapping(mapping)
    rescue StandardError => e
      summary.mappings.count(:skipped, unresolvable_reason(e))
    end

    def plan_or_enqueue_mapping(mapping)
      if dry_run?
        bucket = OutboxEntry.exists?(idempotency_key: mapping.idempotency_key) ? :already_enqueued : :enqueued
        return summary.mappings.count(bucket, mapping.confidence)
      end

      entry = enqueue("backfill mapping for #{mapping.item_key}") do
        OutboxEntry.enqueue(record_kind: :mapping, payload: mapping.payload, **mapping.enqueue_context)
      end
      return summary.mappings.count(:skipped, "enqueue_failed") if entry.nil?

      summary.mappings.count(entry.previously_new_record? ? :enqueued : :already_enqueued, mapping.confidence)
    end

    def enqueue(description, &)
      Outbox::IsolatedWrite.call(description, &)
    end

    def item_service(item)
      Base::Service.service_identifier_for(item.provider)
    rescue StandardError
      UNKNOWN_SERVICE
    end

    def unresolvable_reason(error)
      "unresolvable_#{error.class.name.underscore}"
    end
  end
end
