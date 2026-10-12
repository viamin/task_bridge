# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox with present-day facts only. It intentionally emits item
  # snapshots, not observation or sync-run history: legacy rows cannot tell
  # us when a past change or run actually happened.
  class Baseline
    DETECTED_BY = "backfill"

    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = Hash.new(0)
      @confidence = Hash.new(0)
      @services = Hash.new(0)
    end

    def run!
      SourceProvenance.run! unless dry_run
      Base::SyncItem.find_each { |item| backfill_item(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
      report
      summary
    end

    private

    attr_reader :dry_run, :output, :summary, :confidence, :services

    def backfill_item(item)
      identity = Outbox::SourceIdentity.for(item)
      return skip(:items, "missing_external_id") if identity[:external_id].blank?

      services[identity[:service_type]] += 1
      summary[:items] += 1
      return if dry_run

      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, identity),
        **item_context(item, identity)
      )
    end

    def backfill_collection(collection)
      mapping_confidence = collection.mapping_confidence || inferred_confidence(collection)
      confidence[mapping_confidence || "incomplete"] += collection.sync_items.size
      if mapping_confidence == "low"
        summary[:withheld_low_confidence_mappings] += collection.sync_items.size
        return
      end
      collection.sync_items.each { |item| backfill_mapping(collection, item) }
    end

    def backfill_mapping(collection, item)
      return skip(:mappings, "missing_external_id") if item.external_id.blank?

      summary[:mappings] += 1
      return if dry_run

      Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: observed_at_for(item))
    end

    def item_payload(item, identity)
      snapshot = item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
      snapshot.except(:version).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at_for(item)),
        source: identity,
        provenance: { detected_by: DETECTED_BY, backfilled_at: iso_timestamp(Time.current) }
      )
    end

    def item_context(item, identity)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: observed_at_for(item)
      }
    end

    def observed_at_for(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at
    end

    def inferred_confidence(collection)
      return "low" if collection.sync_items.size < 2

      SyncMappingProvenance.preferred_for(collection.sync_items.to_a).fetch(:confidence)
    end

    def skip(kind, reason)
      summary[:"skipped_#{kind}_#{reason}"] += 1
    end

    def report
      output.puts "Backfill #{dry_run ? 'dry run: ' : 'complete: '}" \
                  "#{summary[:items]} item snapshots, #{summary[:mappings]} mapping memberships"
      output.puts "Services: #{services.sort.map { |name, count| "#{name}=#{count}" }.join(', ').presence || 'none'}"
      output.puts "Mapping confidence: #{confidence.sort.map { |name, count| "#{name}=#{count}" }.join(', ').presence || 'none'}"
      skipped = summary.select { |key, _| key.to_s.start_with?("skipped_") }
      output.puts "Skipped/incomplete: #{skipped.map { |key, count| "#{key}=#{count}" }.join(', ').presence || 'none'}"
      output.puts "Withheld low-confidence mappings: #{summary[:withheld_low_confidence_mappings]}"
    end

    def iso_timestamp(value)
      value&.utc&.iso8601(6)
    end
  end
end
