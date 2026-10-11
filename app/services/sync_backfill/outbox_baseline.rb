# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web with current state that predates the observation
  # pipeline. These are deliberately item snapshots, not historical events:
  # consumers can establish a baseline without treating it as a source change.
  class OutboxBaseline
    PUBLISHED_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = Hash.new(0)
      @services = Hash.new { |hash, key| hash[key] = Hash.new(0) }
      @confidences = Hash.new(0)
    end

    def run!
      SourceProvenance.run! unless dry_run?
      baseline_items
      baseline_mappings
      result
    end

    private

    attr_reader :summary, :services, :confidences

    def baseline_items
      Base::SyncItem.includes(:sync_collection).find_each do |item|
        identity = Outbox::SourceIdentity.for(item)
        if identity[:external_id].blank?
          skip_item(identity)
          next
        end

        enqueue_item(item, identity)
      end
    end

    def baseline_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        collection.sync_items.each { |item| baseline_mapping(collection, item) }
      end
    end

    def baseline_mapping(collection, item)
      confidence = collection.mapping_confidence
      confidences[confidence.presence || "incomplete"] += 1
      services[Outbox::SourceIdentity.for(item)[:service_type]]["mapping_confidence_#{confidence.presence || 'incomplete'}"] += 1
      return skip_mapping(collection, item, "incomplete") if confidence.blank? || collection.mapping_method.blank?
      return skip_mapping(collection, item, "low_confidence") unless PUBLISHED_CONFIDENCES.include?(confidence)
      return skip_mapping(collection, item, "missing_external_id") if item.external_id.blank?

      enqueue_mapping(collection, item)
    end

    def enqueue_item(item, identity)
      observed_at = baseline_time_for(item)
      payload = item_payload(item, identity, observed_at)
      enqueue(:item, payload, identity, observed_at)
    end

    def enqueue_mapping(collection, item)
      observed_at = baseline_time_for(collection)
      identity = Outbox::SourceIdentity.for(item)
      payload = Outbox::MappingEmitter.payload_for(collection, item, observed_at:)
      enqueue(:mapping, payload, identity, observed_at, sync_collection_id: collection.id)
    end

    def enqueue(record_kind, payload, identity, observed_at, sync_collection_id: nil)
      context = {
        service_type: identity[:service_type], service_instance: identity[:service_instance],
        external_id: identity[:external_id], observed_at:, sync_collection_id:
      }
      key = Outbox::IdempotencyKey.for(record_kind:, **context)
      count = OutboxEntry.exists?(idempotency_key: key) ? "existing" : "enqueued"
      OutboxEntry.enqueue(record_kind:, payload:, idempotency_key: key, **context) unless dry_run?
      summary["#{record_kind}_#{count}"] += 1
      services[identity[:service_type]]["#{record_kind}_#{count}"] += 1
    end

    def item_payload(item, identity, observed_at)
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        item_key: [identity[:service_instance], identity[:external_id]].join(":"),
        entity_type: "task",
        observed_at: iso_timestamp(observed_at),
        title: item.title,
        status: item.completed? ? "completed" : "open",
        is_deleted: false,
        completed_at: iso_timestamp(item.completed_at || item.completed_on),
        source_created_at: iso_timestamp(item.source_created_at),
        source_updated_at: iso_timestamp(item.source_updated_at || item.last_modified),
        source: identity,
        provenance: { detected_by: "backfill", backfilled_at: iso_timestamp(observed_at) }
      }.compact
    end

    def baseline_time_for(record)
      return record.mapping_established_at || record.mapping_last_observed_at || record.updated_at || record.created_at if record.is_a?(SyncCollection)

      record.first_observed_at || record.last_observed_at || record.updated_at || record.created_at
    end

    def skip_item(identity)
      summary["item_skipped_incomplete"] += 1
      services[identity[:service_type]]["item_skipped_incomplete"] += 1
    end

    def skip_mapping(collection, item, reason)
      identity = Outbox::SourceIdentity.for(item)
      summary["mapping_skipped_#{reason}"] += 1
      services[identity[:service_type]]["mapping_skipped_#{reason}"] += 1
      collection
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end

    def dry_run?
      @dry_run
    end

    def result
      summary.merge("services" => services, "mapping_confidences" => confidences)
    end
  end
end
