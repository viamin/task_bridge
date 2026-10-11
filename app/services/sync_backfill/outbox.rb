# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox from known local state before publication is enabled.
  # It creates current-state snapshots, not synthetic historical observations.
  class Outbox
    PUBLISHED_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
      @summary = { dry_run:, items: Hash.new(0), mappings: Hash.new(0), skipped: Hash.new(0) }
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :dry_run, :now, :summary

    def backfill_items
      Base::SyncItem.find_each { |item| backfill_item(item) }
    end

    def backfill_item(item)
      return skip(:items_missing_external_id) if item.external_id.blank?

      identity = ::Outbox::SourceIdentity.for(item)
      summary[:items][identity[:service_type]] += 1
      return if dry_run

      ::OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, identity),
        **item_context(item, identity)
      )
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
    end

    def backfill_collection(collection)
      collection.sync_items.each { |item| backfill_membership(collection, item) }
    end

    def backfill_membership(collection, item)
      return skip(:mappings_missing_external_id) if item.external_id.blank?
      return skip("mappings_#{collection.mapping_confidence || 'incomplete'}") unless publishable_mapping?(collection)

      summary[:mappings][collection.mapping_confidence] += 1
      return if dry_run

      ::Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: mapping_observed_at(collection))
    end

    def publishable_mapping?(collection)
      collection.mapping_method.present? && PUBLISHED_CONFIDENCES.include?(collection.mapping_confidence)
    end

    def item_payload(item, identity)
      published_snapshot(item).merge(
        contract_version: ::OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(item_observed_at(item)),
        source: identity,
        provenance: { detected_by: "backfill", backfilled_at: iso_timestamp(now) }
      )
    end

    def item_context(item, identity)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: item_observed_at(item)
      }
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? iso_timestamp(value) : value }
    end

    def item_observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at || now
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.mapping_established_at || collection.updated_at || collection.created_at || now
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end

    def skip(reason)
      summary[:skipped][reason.to_s] += 1
    end
  end
end
