# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from locally synchronized
  # records. This deliberately emits item snapshots, rather than observations:
  # the old rows tell us what exists now, not when a historical change occurred.
  class OutboxBaseline
    BACKFILL_DETECTED_BY = "backfill"
    PUBLISHABLE_MAPPING_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
      @summary = Summary.new(dry_run:)
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary.to_h
    end

    private

    attr_reader :dry_run, :now, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        identity = Outbox::SourceIdentity.for(item)
        unless identity[:external_id].present?
          summary.skip_item(identity[:service_type], :missing_external_id)
          next
        end

        summary.item(identity[:service_type])
        next if dry_run

        OutboxEntry.enqueue(
          record_kind: :item,
          payload: item_payload(item, identity),
          **item_context(item, identity)
        )
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        members = collection.sync_items.select { |item| item.external_id.present? }
        confidence = mapping_confidence_for(collection)
        unless PUBLISHABLE_MAPPING_CONFIDENCES.include?(confidence)
          summary.withhold_mapping(confidence || "unknown", members.count)
          next
        end

        summary.mapping(confidence, members.count)
        next if dry_run

        Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at: mapping_observed_at(collection))
      end
    end

    def item_payload(item, identity)
      snapshot = item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? value.utc.iso8601(6) : value
      end
      snapshot.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(item_observed_at(item)),
        source: identity,
        provenance: {
          detected_by: BACKFILL_DETECTED_BY,
          backfilled_at: iso_timestamp(now),
          baseline: true
        }
      )
    end

    def item_context(item, identity)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: item_observed_at(item)
      }
    end

    def item_observed_at(item)
      item.last_observed_at || item.source_updated_at || item.last_modified || item.updated_at || item.created_at
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.mapping_established_at || collection.updated_at || collection.created_at
    end

    def mapping_confidence_for(collection)
      return collection.mapping_confidence unless dry_run && collection.mapping_confidence.blank?

      SyncBackfill::SourceProvenance.mapping_provenance_for(collection).fetch(:confidence)
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end

    # The task output is intentionally data-oriented so operators can retain
    # a dry-run report before enabling publication. Counts describe candidates;
    # reruns are safe because OutboxEntry's idempotency key owns deduplication.
    class Summary
      def initialize(dry_run:)
        @dry_run = dry_run
        @items_by_service = Hash.new(0)
        @mappings_by_confidence = Hash.new(0)
        @withheld_by_confidence = Hash.new(0)
        @skipped_items = Hash.new(0)
      end

      def item(service_type)
        @items_by_service[service_type] += 1
      end

      def skip_item(service_type, reason)
        @skipped_items["#{service_type}:#{reason}"] += 1
      end

      def mapping(confidence, count)
        @mappings_by_confidence[confidence] += count
      end

      def withhold_mapping(confidence, count)
        @withheld_by_confidence[confidence] += count
      end

      def to_h
        {
          dry_run: @dry_run,
          items: { candidates_by_service: @items_by_service, skipped: @skipped_items },
          mappings: { candidates_by_confidence: @mappings_by_confidence, withheld_by_confidence: @withheld_by_confidence },
          sync_runs: { emitted: 0, skipped: "no reliable historical timestamps" }
        }
      end
    end
  end
end
