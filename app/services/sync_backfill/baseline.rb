# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox with current state only. These rows deliberately do not
  # claim a historical transition: the provenance marks them as a backfill.
  class Baseline
    PUBLISHED_MAPPING_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = { items: Hash.new(0), mappings: Hash.new(0), skipped: Hash.new(0) }
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      Base::SyncItem.find_each { |item| backfill_item(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
      summary
    end

    private

    attr_reader :dry_run, :summary

    def backfill_item(item)
      return skip(:items, item, "missing_external_id") if item.external_id.blank?

      observed_at = item.last_observed_at || item.updated_at || item.created_at
      identity = Outbox::SourceIdentity.for(item)
      payload = item_payload(item, identity, observed_at)
      return count(:items, identity[:service_type]) if dry_run

      entry = OutboxEntry.enqueue(record_kind: :item, payload:, **item_context(identity, item, observed_at))
      item.update_column(:last_snapshot, payload.except(:idempotency_key)) if entry && item.last_snapshot.blank?
      count(:items, identity[:service_type])
    end

    def backfill_collection(collection)
      confidence = collection.mapping_confidence
      return skip(:mappings, collection, "low_confidence") unless PUBLISHED_MAPPING_CONFIDENCES.include?(confidence)

      members = collection.sync_items.select { |item| item.external_id.present? }
      return skip(:mappings, collection, "incomplete_membership") if members.empty?

      members.length.times { count(:mappings, confidence) }
      return if dry_run

      observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at
      Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at:)
    end

    def item_payload(item, identity, observed_at)
      context = item_context(identity, item, observed_at)
      key = Outbox::IdempotencyKey.for(record_kind: :item, **context)
      snapshot = item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? timestamp(value) : value
      end
      snapshot.merge(
        observed_at: timestamp(observed_at),
        source: identity,
        idempotency_key: key,
        provenance: { detected_by: "backfill", backfilled_at: timestamp(observed_at) }
      )
    end

    def item_context(identity, item, observed_at)
      {
        service_type: identity[:service_type], service_instance: identity[:service_instance],
        external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified, observed_at:
      }
    end

    def timestamp(value)
      value&.utc&.iso8601(6)
    end

    def count(kind, key)
      summary.fetch(kind)[key] += 1
    end

    def skip(kind, record, reason)
      key = kind == :mappings ? record.mapping_confidence.presence || "unknown" : record.provider.to_s.underscore
      summary[:skipped]["#{kind}.#{key}.#{reason}"] += 1
    end
  end
end
