# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from records that existed
  # before the observation pipeline. This emits baseline snapshots, never
  # historical change observations, and is safe to rerun because the
  # backfill observation timestamp is stored on the source record.
  class Outbox
    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = Summary.new
    end

    def run!
      Base::SyncItem.find_each { |item| backfill_item(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
      output.puts(summary.to_json) if dry_run
      summary.to_h
    end

    private

    attr_reader :dry_run, :output, :summary

    def backfill_item(item)
      return summary.skip_item(item, "missing_external_id") if item.external_id.blank?

      identity = ::Outbox::SourceIdentity.for(item)
      return summary.skip_item(item, "missing_source_identity") if identity.values_at(:service_type, :service_instance, :external_id).any?(&:blank?)

      summary.item(item)
      return if dry_run

      OutboxEntry.enqueue(record_kind: :item, payload: item_payload(item, identity), **item_context(item, identity))
    end

    def backfill_collection(collection)
      collection.sync_items.each { |item| backfill_membership(collection, item) }
    end

    def backfill_membership(collection, item)
      return summary.skip_mapping(collection, "missing_external_id") if item.external_id.blank?
      return summary.skip_mapping(collection, "low_confidence") unless publishable_mapping?(collection)

      summary.mapping(mapping_provenance(collection).fetch(:confidence))
      return if dry_run

      ::Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: mapping_observed_at(collection))
    end

    def publishable_mapping?(collection)
      %w[high medium].include?(mapping_provenance(collection).fetch(:confidence))
    end

    def item_payload(item, identity)
      snapshot = item.normalized_snapshot
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        item_key: item.item_key,
        entity_type: snapshot[:entity_type],
        observed_at: timestamp(item_observed_at(item)),
        title: snapshot[:title],
        status: snapshot[:status],
        is_deleted: snapshot[:is_deleted],
        completed_at: timestamp(snapshot[:completed_at]),
        source_created_at: timestamp(snapshot[:source_created_at]),
        source_updated_at: timestamp(snapshot[:source_updated_at]),
        due_at: timestamp(snapshot[:due_at]),
        started_at: timestamp(snapshot[:start_at]),
        tags: snapshot[:tags],
        parent: { external_id: snapshot[:parent_item_id], item_key: nil },
        source: identity.merge(source_collection_keys: []),
        sync_collection: sync_collection(item),
        source_metadata: snapshot[:metadata],
        provenance: { detected_by: "backfill", baseline: true, backfilled_at: timestamp(item_observed_at(item)) }
      }.compact
    end

    def item_context(item, identity)
      {
        service_type: identity[:service_type], service_instance: identity[:service_instance],
        external_id: identity[:external_id], observed_at: item_observed_at(item),
        source_updated_at: item.source_updated_at || item.last_modified,
        sync_collection_id: item.sync_collection_id
      }
    end

    def sync_collection(item)
      return if item.sync_collection.blank?

      collection = item.sync_collection
      { sync_collection_id: collection.id, membership_role: "member",
        mapping_confidence: mapping_confidence(collection), mapping_source: mapping_source(collection) }
    end

    def mapping_confidence(collection)
      confidence = mapping_provenance(collection).fetch(:confidence)
      ::Outbox::MappingEmitter::CONFIDENCE.fetch(confidence, confidence)
    end

    def mapping_source(collection)
      method = mapping_provenance(collection).fetch(:method)
      ::Outbox::MappingEmitter::SOURCE.fetch(method, method)
    end

    def mapping_provenance(collection)
      return { method: collection.mapping_method, confidence: collection.mapping_confidence } if collection.mapping_method.present?

      items = collection.sync_items.to_a.compact
      return { method: "manual_backfill", confidence: "low" } if items.length < 2

      SyncMappingProvenance.preferred_for(items)
    end

    def item_observed_at(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_observed_at(collection)
      collection.mapping_established_at || collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def timestamp(value)
      value&.utc&.iso8601(6)
    end
  end
end
