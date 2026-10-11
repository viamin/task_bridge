# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox with current state only. It deliberately does not emit
  # observations or sync runs: neither is a historical fact we can recover
  # from the pre-outbox database.
  class OutboxBaseline
    def self.run!(dry_run: false, output: $stdout, backfilled_at: Time.current)
      new(dry_run:, output:, backfilled_at:).run!
    end

    def initialize(dry_run:, output:, backfilled_at:)
      @dry_run = dry_run
      @output = output
      @backfilled_at = backfilled_at
      @summary = empty_summary
    end

    def run!
      SourceProvenance.run! unless dry_run?
      backfill_items
      backfill_mappings
      output.puts(JSON.generate(summary)) if dry_run?
      summary
    end

    private

    attr_reader :backfilled_at, :output, :summary

    def backfill_items
      Base::SyncItem.find_each { |item| backfill_item(item) }
    end

    def backfill_item(item)
      return skip_item("missing_external_id") if item.external_id.blank?

      identity = Outbox::SourceIdentity.for(item)
      return skip_item("missing_service") if identity[:service_type].blank?

      increment(:items, :would_enqueue, identity[:service_type])
      return if dry_run?

      observed_at = observed_at_for(item)
      snapshot = serialized_snapshot(item, observed_at)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: snapshot.merge(provenance: baseline_provenance),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
      item.update_column(:last_snapshot, snapshot) if item.last_snapshot.blank?
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
    end

    def backfill_collection(collection)
      collection.sync_items.each { |item| backfill_membership(collection, item) }
    end

    def backfill_membership(collection, item)
      return skip_mapping("missing_external_id") if item.external_id.blank?

      identity = Outbox::SourceIdentity.for(item)
      return skip_mapping("missing_service") if identity[:service_type].blank?

      confidence = mapping_confidence_for(collection)
      contract_confidence = Outbox::MappingEmitter.contract_confidence(confidence)
      if contract_confidence == "tentative"
        increment(:mappings, :withheld, contract_confidence, identity[:service_type])
        return
      end

      increment(:mappings, :would_enqueue, contract_confidence, identity[:service_type])
      return if dry_run?

      Outbox::MappingEmitter.emit_for_members(
        collection,
        members: [item],
        observed_at: observed_at_for(collection),
        emission_provenance: baseline_provenance
      )
    end

    def serialized_snapshot(item, observed_at)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end.merge(observed_at: iso_timestamp(observed_at))
    end

    def mapping_confidence_for(collection)
      return collection.mapping_confidence if collection.mapping_confidence.present?

      SourceProvenance.mapping_provenance_for(collection).fetch(:confidence)
    end

    def baseline_provenance
      {
        detected_by: "backfill",
        baseline: true,
        backfilled_at: iso_timestamp(backfilled_at)
      }
    end

    def observed_at_for(record)
      record.try(:last_observed_at) || record.updated_at || record.created_at || backfilled_at
    end

    def skip_item(reason)
      increment(:items, :skipped, reason)
    end

    def skip_mapping(reason)
      increment(:mappings, :skipped, reason)
    end

    def increment(*keys)
      leaf = keys.reduce(summary) { |counts, key| counts[key.to_s] ||= {} }
      leaf["count"] = leaf.fetch("count", 0) + 1
    end

    def empty_summary
      {
        "dry_run" => dry_run?,
        "items" => { "would_enqueue" => {}, "skipped" => {} },
        "mappings" => { "would_enqueue" => {}, "withheld" => {}, "skipped" => {} },
        "sync_runs" => { "skipped" => "historical timestamps unavailable" }
      }
    end

    def dry_run?
      @dry_run
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
