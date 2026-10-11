# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web with the current local state without inventing a
  # historical change event.  The outbox unique idempotency keys make this safe
  # to rerun after an interrupted backfill.
  class OutboxBaseline
    BACKFILL_DETECTED_BY = "backfill"

    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = Hash.new { |hash, key| hash[key] = empty_counts }
    end

    def run!
      SourceProvenance.run! unless dry_run?
      backfill_items
      backfill_mappings
      print_summary
      summary
    end

    private

    attr_reader :output, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        item.external_id.present? ? backfill_item(item) : increment(item, :skipped_incomplete_items)
      end
    end

    def backfill_item(item)
      observed_at = item.last_observed_at || item.updated_at || item.created_at
      entry = existing_item_entry(item, observed_at)
      increment(item, entry ? :existing_items : :items)
      return if dry_run? || entry

      OutboxEntry.enqueue(record_kind: :item, payload: item_payload(item, observed_at), **item_context(item, observed_at))
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence.presence || "low"
        collection.sync_items.each { |item| backfill_mapping(collection, item, confidence) }
      end
    end

    def backfill_mapping(collection, item, confidence)
      return increment(item, :"withheld_#{confidence}_mappings") unless %w[high medium].include?(confidence)
      return increment(item, :skipped_incomplete_mappings) if item.external_id.blank?

      observed_at = mapping_observed_at(collection)
      entry = existing_mapping_entry(collection, item, observed_at)
      increment(item, entry ? :"existing_#{confidence}_mappings" : :"#{confidence}_mappings")
      return if dry_run? || entry

      Outbox::MappingEmitter.emit_backfill_for_members(collection, members: [item], observed_at:)
    end

    def item_payload(item, observed_at)
      serialized_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        provenance: { detected_by: BACKFILL_DETECTED_BY, initial_observation: true },
        backfilled_at: timestamp(Time.current)
      )
    end

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? timestamp(value) : value }
    end

    def item_context(item, observed_at)
      identity = Outbox::SourceIdentity.for(item)
      identity.slice(:service_type, :service_instance, :external_id)
              .merge(sync_collection_id: item.sync_collection_id, source_updated_at: item.source_updated_at || item.last_modified,
                     observed_at:)
    end

    def existing_item_entry(item, observed_at)
      OutboxEntry.find_by(idempotency_key: Outbox::IdempotencyKey.for(record_kind: :item, observed_at:, **item_context(item, observed_at)))
    end

    def existing_mapping_entry(collection, item, observed_at)
      identity = Outbox::SourceIdentity.for(item)
      OutboxEntry.find_by(
        idempotency_key: Outbox::IdempotencyKey.for(record_kind: :mapping, observed_at:, sync_collection_id: collection.id,
                                                    **identity.slice(:service_instance, :external_id))
      )
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.mapping_established_at || collection.updated_at || collection.created_at
    end

    def increment(item, key)
      summary[Outbox::SourceIdentity.for(item).fetch(:service_type)][key] += 1
    end

    def empty_counts
      Hash.new(0)
    end

    def print_summary
      output.puts JSON.pretty_generate(summary: summary, dry_run: dry_run?)
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end

    def dry_run?
      @dry_run
    end
  end
end
