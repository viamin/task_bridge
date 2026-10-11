# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from existing local sync
  # data. This intentionally creates item snapshots, not historical
  # observations: the first live sync remains the first change observation.
  class OutboxBaseline
    PUBLISHABLE_MAPPING_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @backfilled_at = Time.current
      @summary = {
        items: { eligible: 0, enqueued: 0, by_service: Hash.new(0) },
        mappings: { eligible: 0, enqueued: 0, by_confidence: Hash.new(0), withheld_low_confidence: 0 },
        skipped: Hash.new(0)
      }
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
      Base::SyncItem.find_each { |item| backfill_item(item) }
    end

    def backfill_item(item)
      return skip(:missing_external_id) if item.external_id.blank?

      identity = Outbox::SourceIdentity.for(item)
      return skip(:incomplete_source_identity) if identity.values_at(:service_type, :service_instance, :external_id).any?(&:blank?)

      summary[:items][:by_service][identity[:service_type]] += 1
      summary[:items][:eligible] += 1
      return if dry_run

      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, identity),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: observed_at_for(item)
      )
      summary[:items][:enqueued] += 1
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
    end

    def backfill_collection(collection)
      confidence = collection.mapping_confidence.to_s
      return skip(:incomplete_mapping_provenance) if confidence.blank?

      members = collection.sync_items.to_a
      unless PUBLISHABLE_MAPPING_CONFIDENCES.include?(confidence)
        summary[:mappings][:withheld_low_confidence] += members.size
        return
      end

      eligible_members = members.reject { |member| member.external_id.blank? }
      summary[:skipped][:mapping_missing_external_id] += members.size - eligible_members.size
      summary[:mappings][:by_confidence][confidence] += eligible_members.size
      summary[:mappings][:eligible] += eligible_members.size
      return if dry_run

      before_count = OutboxEntry.where(record_kind: "mapping", sync_collection_id: collection.id).count
      Outbox::MappingEmitter.emit_for_members(collection, members: eligible_members, observed_at: observed_at_for(collection))
      summary[:mappings][:enqueued] += OutboxEntry.where(record_kind: "mapping", sync_collection_id: collection.id).count - before_count
    end

    def item_payload(item, identity)
      item.normalized_snapshot.deep_transform_values { |value| timestamp(value) }.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at_for(item)),
        source: identity,
        provenance: {
          detected_by: "backfill",
          backfilled_at: timestamp(backfilled_at),
          initial_observation: true
        }
      )
    end

    def observed_at_for(record)
      record.try(:last_observed_at) || record.try(:mapping_last_observed_at) || record.updated_at || record.created_at
    end

    def timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end

    def skip(reason)
      summary[:skipped][reason] += 1
    end
  end
end
