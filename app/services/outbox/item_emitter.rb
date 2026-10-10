# frozen_string_literal: true

module Outbox
  # Publishes the RDR #215 "Minimum Normalized Item Snapshot" — the
  # current-state document for one source item — as an `item` outbox row,
  # built from Base::SyncItem#normalized_snapshot plus the shared
  # Outbox::SourceIdentity spine. Live change history flows through
  # `observation` rows (which embed the snapshot on discovery); this
  # emitter is the producer for current-state publication and baseline
  # backfills. `notes_preview` is deliberately never emitted here: the
  # per-source note-export opt-in does not exist yet (#215).
  class ItemEmitter
    MEMBERSHIP_ROLE = Outbox::MappingEmitter::MEMBERSHIP_ROLE

    def self.emit_for_item(item, observed_at: nil)
      new(item, observed_at:).emit
    end

    def initialize(item, observed_at:)
      @item = item
      @observed_at = observed_at || item.last_observed_at || item.updated_at
    end

    def emit
      return if item.options[:pretend] || !item.persisted? || item.external_id.blank?

      Outbox::IsolatedWrite.call("item snapshot for #{item.item_key}") do
        OutboxEntry.enqueue(record_kind: :item, payload:, **enqueue_context)
      end
    end

    private

    attr_reader :item, :observed_at

    def payload
      snapshot = item.normalized_snapshot
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        item_key: snapshot[:item_key],
        entity_type: snapshot[:entity_type],
        observed_at: iso_timestamp(observed_at),
        title: snapshot[:title],
        status: snapshot[:status],
        is_deleted: snapshot[:is_deleted],
        completed_at: iso_timestamp(snapshot[:completed_at]),
        source_created_at: iso_timestamp(snapshot[:source_created_at]),
        source_updated_at: iso_timestamp(snapshot[:source_updated_at]),
        due_at: iso_timestamp(snapshot[:due_at]),
        started_at: iso_timestamp(snapshot[:start_at]),
        tags: snapshot[:tags],
        parent: parent_payload,
        sync_collection: sync_collection_payload,
        source: identity,
        source_metadata: snapshot[:metadata]
      }
    end

    def enqueue_context
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        source_updated_at: item.source_updated_at,
        observed_at:
      }
    end

    def identity
      @identity ||= Outbox::SourceIdentity.for(item)
    end

    def parent_payload
      parent = item.parent_item_id ? item.class.find_by(id: item.parent_item_id) : nil
      { external_id: parent&.external_id, item_key: parent&.item_key }
    end

    def sync_collection_payload
      return unless item.sync_collection_id

      collection = item.sync_collection
      {
        sync_collection_id: item.sync_collection_id,
        membership_role: MEMBERSHIP_ROLE,
        mapping_confidence: translate(Outbox::MappingEmitter::CONFIDENCE, collection&.mapping_confidence),
        mapping_source: translate(Outbox::MappingEmitter::SOURCE, collection&.mapping_method)
      }
    end

    # Unknown internal values pass through unchanged: version 1 consumers
    # must ignore unknown values rather than break.
    def translate(vocabulary, value)
      value.nil? ? nil : vocabulary.fetch(value, value)
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
