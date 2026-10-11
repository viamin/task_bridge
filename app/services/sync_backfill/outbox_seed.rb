# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox with the current state known before observation
  # publication was introduced.  These rows establish a baseline, not a
  # history of source changes.
  class OutboxSeed
    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = Hash.new(0)
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      seed_items
      seed_mappings
      output.puts(JSON.generate(summary))
      summary
    end

    private

    attr_reader :dry_run, :output, :summary

    def seed_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          increment(:items_skipped_incomplete, item)
          next
        end

        increment(:items, item)
        enqueue_item(item) unless dry_run
      end
    end

    def seed_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        collection.sync_items.each { |item| seed_mapping(collection, item) }
      end
    end

    def seed_mapping(collection, item)
      confidence = collection.mapping_confidence.presence || "low"
      increment("mappings_#{confidence}", item)
      return increment(:mappings_withheld_low, item) if confidence == "low"
      return increment(:mappings_skipped_incomplete, item) if item.external_id.blank?

      Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: observed_at(item)) unless dry_run
    end

    def enqueue_item(item)
      observed = observed_at(item)
      identity = Outbox::SourceIdentity.for(item)
      key = Outbox::IdempotencyKey.for(record_kind: :item, observed_at: observed, **identity)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, observed, key),
        idempotency_key: key,
        observed_at: observed,
        source_updated_at: item.source_updated_at || item.last_modified,
        service_type: identity.fetch(:service_type),
        service_instance: identity.fetch(:service_instance),
        external_id: identity.fetch(:external_id)
      )
    end

    def item_payload(item, observed, key)
      item.normalized_snapshot.deep_transform_values { |value| timestamp(value) }.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        idempotency_key: key,
        observed_at: timestamp(observed),
        provenance: { detected_by: "backfill", baseline: true, backfilled_at: timestamp(Time.current) }
      )
    end

    def observed_at(item)
      item.last_observed_at || item.first_observed_at || item.source_updated_at || item.last_modified || item.updated_at || item.created_at
    end

    def timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end

    def increment(kind, item)
      summary["#{kind}.#{Outbox::SourceIdentity.for(item)[:service_type]}"] += 1
    end
  end
end
