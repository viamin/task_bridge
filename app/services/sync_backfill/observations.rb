# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox with current state only.  It deliberately emits no
  # observation or sync-run records: neither historical changes nor reliable
  # run timings can be reconstructed from the old sync tables.
  class Observations
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @backfilled_at = Time.current
      @summary = {}
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :backfilled_at, :dry_run, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        item.external_id.present? ? backfill_item(item) : skip(:items_missing_external_id)
      end
    end

    def backfill_item(item)
      increment(:items, Outbox::SourceIdentity.for(item)[:service_type])
      return if dry_run

      observed_at = item.last_observed_at || item.updated_at || item.created_at || backfilled_at
      identity = Outbox::SourceIdentity.for(item)
      key = Outbox::IdempotencyKey.for(record_kind: :item, observed_at:, **identity)
      OutboxEntry.enqueue(record_kind: :item, payload: item_payload(item, key, observed_at),
                          idempotency_key: key, observed_at:, source_updated_at: item.source_updated_at,
                          **outbox_identity(identity))
      item.update_column(:last_snapshot, published_snapshot(item)) if item.last_snapshot.blank?
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        backfill_collection(collection)
      end
    end

    def backfill_collection(collection)
      confidence = mapping_provenance(collection).fetch(:confidence)
      increment(:mappings, confidence)
      return skip(:mappings_low_confidence) unless PUBLISHABLE_CONFIDENCES.include?(confidence)
      return skip(:mappings_without_members) if collection.sync_items.empty?
      return if dry_run

      Outbox::MappingEmitter.emit_for_members(
        collection, members: collection.sync_items, observed_at: mapping_observed_at(collection)
      )
    end

    def mapping_provenance(collection)
      return { confidence: collection.mapping_confidence } if collection.mapping_confidence.present?

      SourceProvenance.provenance_for(collection)
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || backfilled_at
    end

    def item_payload(item, key, observed_at)
      published_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        idempotency_key: key,
        observed_at: iso_timestamp(observed_at),
        provenance: { detected_by: "backfill", backfilled_at: iso_timestamp(backfilled_at) }
      )
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? iso_timestamp(value) : value }
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end

    def outbox_identity(identity)
      identity.slice(:service_type, :service_instance, :external_id)
    end

    def increment(category, value)
      summary[category] ||= Hash.new(0)
      summary[category][value] += 1
    end

    def skip(reason)
      summary[:skipped] ||= Hash.new(0)
      summary[:skipped][reason] += 1
    end
  end
end
