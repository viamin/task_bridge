# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox with current state only. These rows are deliberately not
  # observations: backfill establishes the starting point for later diffs.
  class ObservationBaseline
    BACKFILL_DETECTED_BY = "backfill"
    PUBLISHED_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = Hash.new(0)
      @services = Hash.new(0)
      @confidences = Hash.new(0)
      @skipped = Hash.new(0)
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      report
    end

    private

    attr_reader :dry_run, :output, :summary, :services, :confidences, :skipped

    def backfill_items
      Base::SyncItem.find_each do |item|
        identity = Outbox::SourceIdentity.for(item)
        next skip(:incomplete_item) if identity[:external_id].blank?

        services[identity[:service_type]] += 1
        summary[:items] += 1
        next if dry_run

        snapshot = published_snapshot(item)
        OutboxEntry.enqueue(record_kind: :item, payload: item_payload(item, snapshot), **item_context(item, identity))
        item.update_column(:last_snapshot, snapshot) if item.last_snapshot.blank?
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence
        confidences[confidence.presence || "incomplete"] += collection.sync_items.size
        unless PUBLISHED_CONFIDENCES.include?(confidence)
          skip(confidence == "low" ? :low_confidence_mapping : :incomplete_mapping)
          next
        end

        collection.sync_items.each { |item| enqueue_mapping(collection, item) }
      end
    end

    def enqueue_mapping(collection, item)
      identity = Outbox::SourceIdentity.for(item)
      return skip(:incomplete_mapping_member) if identity[:external_id].blank?

      summary[:mappings] += 1
      return if dry_run

      Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: mapping_observed_at(collection))
    end

    def item_context(item, identity)
      { service_type: identity[:service_type], service_instance: identity[:service_instance],
        external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified, observed_at: item_observed_at(item) }
    end

    def item_payload(item, snapshot)
      timestamp = iso_timestamp(item_observed_at(item))
      { contract_version: OutboxEntry::PAYLOAD_VERSION, observed_at: timestamp, backfilled_at: timestamp,
        snapshot:, provenance: { detected_by: BACKFILL_DETECTED_BY, baseline: true } }
    end

    def item_observed_at(item)
      item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? iso_timestamp(value) : value }
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end

    def skip(reason)
      skipped[reason] += 1
      nil
    end

    def report
      result = { dry_run:, items: summary[:items], mappings: summary[:mappings], services:, confidence: confidences,
                 skipped: }
      output.puts(JSON.generate(result))
      result
    end
  end
end
