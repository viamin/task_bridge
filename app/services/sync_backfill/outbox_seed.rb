# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from pre-publication sync
  # data. It deliberately emits item snapshots, not observations: a backfill
  # is a baseline, never evidence that a source changed at that time.
  class OutboxSeed
    BACKFILL_DETECTED_BY = "backfill"
    PUBLISHABLE_MAPPING_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = {
        items: Hash.new(0),
        mappings: Hash.new { |hash, confidence| hash[confidence] = Hash.new(0) },
        skipped: Hash.new(0)
      }
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run?
      seed_items
      seed_mappings
      summary
    end

    private

    attr_reader :summary

    def seed_items
      Base::SyncItem.find_each do |item|
        item.external_id.present? ? seed_item(item) : skip(:missing_external_id)
      end
    end

    def seed_item(item)
      identity = Outbox::SourceIdentity.for(item)
      observed_at = baseline_at(item)
      increment(:items, identity[:service_type])
      return if dry_run?

      snapshot = published_snapshot(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: snapshot.merge(provenance: baseline_provenance(observed_at)),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
      item.update_column(:last_snapshot, snapshot) if item.last_snapshot.blank?
    end

    def seed_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = mapping_confidence(collection)
        members = collection.sync_items.select { |item| item.external_id.present? }
        unless PUBLISHABLE_MAPPING_CONFIDENCES.include?(confidence)
          members.each { |item| increment(:mappings, Outbox::SourceIdentity.for(item)[:service_type], confidence) }
          skip(:low_confidence_mapping, members.length)
          skip(:incomplete_mapping) if members.empty?
          next
        end

        skip(:incomplete_mapping) if members.empty?
        members.each { |item| increment(:mappings, Outbox::SourceIdentity.for(item)[:service_type], confidence) }
        next if dry_run? || members.empty?

        Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at: mapping_at(collection))
      end
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? timestamp(value) : value
      end.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(baseline_at(item)),
        baseline: true
      )
    end

    def baseline_provenance(observed_at)
      { detected_by: BACKFILL_DETECTED_BY, backfilled_at: timestamp(observed_at) }
    end

    def baseline_at(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_at(collection)
      collection.mapping_established_at || collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def mapping_confidence(collection)
      collection.mapping_confidence || inferred_mapping_provenance(collection).fetch(:confidence)
    end

    def inferred_mapping_provenance(collection)
      items = collection.sync_items.to_a
      return { confidence: "low" } if items.length < 2

      SyncMappingProvenance.preferred_for(items)
    end

    def increment(kind, service, confidence = nil)
      return summary[:items][service] += 1 if kind == :items

      summary[:mappings][confidence][service] += 1
    end

    def skip(reason, count = 1)
      summary[:skipped][reason] += count
    end

    def dry_run?
      @dry_run
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end
  end
end
