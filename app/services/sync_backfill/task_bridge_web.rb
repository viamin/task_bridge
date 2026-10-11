# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's outbox from already-synchronized local state. This
  # deliberately creates current-state snapshots, not change-history events.
  class TaskBridgeWeb
    BACKFILL_DETECTED_BY = "backfill"

    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = Summary.new
    end

    def run!
      SyncBackfill::SourceProvenance.run! unless dry_run?
      backfill_items
      backfill_mappings
      output.puts(summary.render(dry_run: dry_run?))
      summary
    end

    private

    attr_reader :output, :summary

    def dry_run?
      @dry_run
    end

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary.skip_item(item, "missing_external_id")
        else
          summary.item(item)
          enqueue_item(item) unless dry_run?
        end
      end
    end

    def enqueue_item(item)
      identity = Outbox::SourceIdentity.for(item)
      observed_at = observed_at_for(item)
      payload = published_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        provenance: {
          detected_by: BACKFILL_DETECTED_BY,
          backfilled_at: iso_timestamp(observed_at)
        }
      )
      OutboxEntry.enqueue(
        record_kind: :item,
        payload:,
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence
        collection.sync_items.each { |item| summary.mapping(item, confidence) }
        next unless %w[high medium].include?(confidence)
        next if dry_run?

        Outbox::MappingEmitter.emit_for_members(
          collection,
          members: collection.sync_items,
          observed_at: mapping_observed_at_for(collection)
        )
      end
    end

    def observed_at_for(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at
    end

    def mapping_observed_at_for(collection)
      collection.mapping_last_observed_at || collection.mapping_established_at || collection.updated_at || collection.created_at
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end

    # Compact, line-oriented dry-run output makes it safe to redirect from a
    # production host without exposing item content or identifiers.
    class Summary
      def initialize
        @items_by_service = Hash.new(0)
        @mappings_by_confidence = Hash.new(0)
        @skipped = Hash.new(0)
      end

      def item(item)
        @items_by_service[Outbox::SourceIdentity.for(item)[:service_type]] += 1
      end

      def mapping(_item, confidence)
        @mappings_by_confidence[confidence.presence || "unknown"] += 1
      end

      def skip_item(_item, reason)
        @skipped[reason] += 1
      end

      def render(dry_run:)
        prefix = dry_run ? "TaskBridge Web backfill dry run" : "TaskBridge Web backfill"
        [
          prefix,
          "items by service: #{format_counts(@items_by_service)}",
          "mappings by confidence: #{format_counts(@mappings_by_confidence)}",
          "skipped/incomplete: #{format_counts(@skipped)}",
          "low-confidence mappings withheld: #{@mappings_by_confidence['low']}"
        ].join("; ")
      end

      private

      def format_counts(counts)
        return "none" if counts.empty?

        counts.sort.map { |name, count| "#{name}=#{count}" }.join(", ")
      end
    end
  end
end
