# frozen_string_literal: true

module Outbox
  # Seeds the local outbox from already-synchronized records. These are
  # current-state baselines, not historical observations: no `observation`
  # rows or synthetic sync runs are created here.
  class Backfill
    def self.run!(dry_run: false, backfilled_at: Time.current)
      new(dry_run:, backfilled_at:).run!
    end

    def initialize(dry_run:, backfilled_at:)
      @dry_run = dry_run
      @backfilled_at = backfilled_at
      @summary = {}
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      result
    end

    private

    attr_reader :dry_run, :backfilled_at, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          count(:items_skipped_incomplete, item)
          next
        end

        count(:items, item)
        next if dry_run

        observed_at = item.last_observed_at || item.updated_at || backfilled_at
        OutboxEntry.enqueue(record_kind: :item, payload: item_payload(item, observed_at), **item_context(item, observed_at))
        item.update_column(:last_snapshot, published_snapshot(item)) if item.last_snapshot.blank?
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence.presence || "low"
        kind = publishable_mapping?(confidence) ? :mappings : :mappings_withheld
        collection.sync_items.each { |item| count(kind, item, confidence:) }
        next if dry_run || kind == :mappings_withheld

        Outbox::MappingEmitter.emit_for_members(
          collection,
          members: collection.sync_items,
          observed_at: collection.mapping_last_observed_at || collection.updated_at || backfilled_at
        )
      end
    end

    def item_payload(item, observed_at)
      published_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        provenance: { detected_by: "backfill", backfilled_at: timestamp(backfilled_at) }
      )
    end

    def item_context(item, observed_at)
      identity = Outbox::SourceIdentity.for(item)
      identity.slice(:service_type, :service_instance, :external_id).merge(
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? timestamp(value) : value }
    end

    def publishable_mapping?(confidence)
      %w[high medium].include?(confidence)
    end

    def count(kind, item, confidence: nil)
      result[:by_service][Outbox::SourceIdentity.for(item)[:service_type]][kind] += 1
      result[:by_confidence][confidence][kind] += 1 if confidence
    end

    def result
      @summary[:by_service] ||= Hash.new { |hash, key| hash[key] = Hash.new(0) }
      @summary[:by_confidence] ||= Hash.new { |hash, key| hash[key] = Hash.new(0) }
      @summary
    end

    def timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
