# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from local synchronized
  # records. Baselines deliberately produce item snapshots, not historical
  # observations or approximate sync runs.
  class Baseline
    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
      @summary = Summary.new(dry_run:, backfilled_at: now)
    end

    def run!
      SourceProvenance.run! unless dry_run
      Base::SyncItem.find_each { |item| seed_item(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| seed_mappings(collection) }
      summary.to_h
    end

    private

    attr_reader :dry_run, :now, :summary

    def seed_item(item)
      identity = Outbox::SourceIdentity.for(item)
      return summary.skip_item("missing_external_id") if identity[:external_id].blank?

      observed_at = item.last_observed_at || item.updated_at || item.created_at
      entry = item_entry(item, identity, observed_at)
      summary.item(identity[:service_type], entry_exists?(:item, entry))
      return if dry_run

      OutboxEntry.enqueue(record_kind: :item, payload: item_payload(item, identity, observed_at), **entry)
    end

    def seed_mappings(collection)
      collection.sync_items.each do |item|
        seed_mapping(collection, item)
      end
    end

    def seed_mapping(collection, item)
      identity = Outbox::SourceIdentity.for(item)
      return summary.skip_mapping("missing_external_id") if identity[:external_id].blank?

      confidence = Outbox::MappingEmitter::CONFIDENCE.fetch(collection.mapping_confidence, collection.mapping_confidence)
      return summary.withhold_mapping(confidence) unless %w[confirmed inferred].include?(confidence)

      observed_at = collection.mapping_last_observed_at || item.last_observed_at || collection.updated_at
      entry = mapping_entry(collection, identity, observed_at)
      summary.mapping(confidence, entry_exists?(:mapping, entry))
      return if dry_run

      OutboxEntry.enqueue(record_kind: :mapping, payload: mapping_payload(collection, item, identity, observed_at), **entry)
    end

    def item_entry(item, identity, observed_at)
      identity.slice(:service_type, :service_instance, :external_id).merge(
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def mapping_entry(collection, identity, observed_at)
      identity.slice(:service_type, :service_instance, :external_id).merge(sync_collection_id: collection.id, observed_at:)
    end

    def entry_exists?(record_kind, entry)
      key = Outbox::IdempotencyKey.for(record_kind:, **entry)
      OutboxEntry.exists?(idempotency_key: key)
    end

    def item_payload(item, identity, observed_at)
      item.normalized_snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        source: identity,
        provenance: { detected_by: "backfill", baseline: true, backfilled_at: timestamp(now) }
      )
    end

    def mapping_payload(collection, item, identity, observed_at)
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        mapping_type: Outbox::MappingEmitter::MAPPING_TYPE,
        observed_at: timestamp(observed_at),
        sync_collection: { sync_collection_id: collection.id, title: collection.title },
        member: identity.merge(item_key: item.item_key),
        membership_role: Outbox::MappingEmitter::MEMBERSHIP_ROLE,
        mapping_confidence: Outbox::MappingEmitter::CONFIDENCE.fetch(collection.mapping_confidence),
        mapping_source: Outbox::MappingEmitter::SOURCE.fetch(collection.mapping_method, collection.mapping_method),
        provenance: { method: collection.mapping_method, confidence: collection.mapping_confidence,
                      metadata: collection.mapping_metadata, detected_by: "backfill", baseline: true,
                      backfilled_at: timestamp(now) }
      }
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end

    # Small accumulator kept separate from the seeding flow so dry-run output
    # has the same shape as a real run without changing any records.
    class Summary
      def initialize(dry_run:, backfilled_at:)
        @dry_run = dry_run
        @backfilled_at = backfilled_at
        @items = Hash.new(0)
        @mappings = Hash.new(0)
        @existing = Hash.new(0)
        @withheld = Hash.new(0)
        @skipped = Hash.new(0)
      end

      def item(service, existing)
        @items[service] += 1
        @existing[:items] += 1 if existing
      end

      def mapping(confidence, existing)
        @mappings[confidence] += 1
        @existing[:mappings] += 1 if existing
      end

      def withhold_mapping(confidence)
        @withheld[confidence || "unknown"] += 1
      end

      def skip_item(reason)
        @skipped["item_#{reason}"] += 1
      end

      def skip_mapping(reason)
        @skipped["mapping_#{reason}"] += 1
      end

      def to_h
        {
          dry_run: @dry_run,
          backfilled_at: @backfilled_at.utc.iso8601(6),
          items: { by_service: @items, existing: @existing[:items] },
          mappings: { by_confidence: @mappings, withheld_by_confidence: @withheld, existing: @existing[:mappings] },
          skipped: @skipped
        }
      end
    end
  end
end
