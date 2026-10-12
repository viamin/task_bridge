# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection without inventing history.
  # Its timestamps come from the local record where available, which keeps the
  # idempotency keys stable across repeated runs.
  class OutboxBaseline
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, io: $stdout)
      new(dry_run:, io:).run!
    end

    def initialize(dry_run:, io:)
      @dry_run = dry_run
      @io = io
      @report = Report.new
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      io.puts(report.to_s)
      report
    end

    private

    attr_reader :dry_run, :io, :report

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          report.skip_item(item, :missing_external_id)
          next
        end

        identity = Outbox::SourceIdentity.for(item)
        report.add_item(identity[:service_type])
        enqueue_item(item, identity) unless dry_run
      end
    end

    def enqueue_item(item, identity)
      observed_at = item_observed_at(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def item_payload(item, observed_at)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
          .merge(
            contract_version: OutboxEntry::PAYLOAD_VERSION,
            observed_at: iso_timestamp(observed_at),
            provenance: { detected_by: "backfill", backfilled_at: iso_timestamp(Time.current) }
          )
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        members = collection.sync_items.to_a.select { |item| item.external_id.present? }
        confidence = collection.mapping_confidence
        if PUBLISHABLE_CONFIDENCES.exclude?(confidence)
          report.skip_mapping(confidence || "incomplete", members.size)
          next
        end

        report.add_mapping(confidence, members.size)
        enqueue_mapping(collection, members) unless dry_run || members.empty?
      end
    end

    def enqueue_mapping(collection, members)
      Outbox::MappingEmitter.emit_for_members(
        collection,
        members:,
        observed_at: collection_observed_at(collection),
        backfilled_at: Time.current
      )
    end

    def item_observed_at(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at || Time.current
    end

    def collection_observed_at(collection)
      collection.mapping_established_at || collection.mapping_last_observed_at || collection.updated_at || collection.created_at || Time.current
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end

    class Report
      def initialize
        @items_by_service = Hash.new(0)
        @mappings_by_confidence = Hash.new(0)
        @skipped_items = Hash.new(0)
        @skipped_mappings = Hash.new(0)
      end

      def add_item(service_type)
        @items_by_service[service_type] += 1
      end

      def add_mapping(confidence, count)
        @mappings_by_confidence[confidence] += count
      end

      def skip_item(_item, reason)
        @skipped_items[reason] += 1
      end

      def skip_mapping(confidence, count)
        @skipped_mappings[confidence] += count
      end

      def to_s
        [
          "TaskBridge outbox baseline backfill summary",
          "items by service: #{format_counts(@items_by_service)}",
          "mappings by confidence: #{format_counts(@mappings_by_confidence)}",
          "skipped items: #{format_counts(@skipped_items)}",
          "skipped mappings: #{format_counts(@skipped_mappings)}"
        ].join("\n")
      end

      private

      def format_counts(counts)
        counts.sort.map { |key, count| "#{key}=#{count}" }.join(", ").presence || "none"
      end
    end
  end
end
