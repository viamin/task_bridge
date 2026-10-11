# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from data synchronized
  # before the outbox existed. These rows are baselines, never source-change
  # observations: future syncs compare against last_snapshot normally.
  class Outbox
    PUBLISHED_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = Hash.new(0)
    end

    def run!
      SyncBackfill::SourceProvenance.run!
      Base::SyncItem.find_each { |item| backfill_item(item) }
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_collection(collection) }
      print_summary if dry_run
      summary
    end

    private

    attr_reader :dry_run, :output, :summary

    def backfill_item(item)
      return skipped_item(item) if item.external_id.blank?

      identity = ::Outbox::SourceIdentity.for(item)
      observed_at = baseline_time(item)
      enqueue_item(item, identity, observed_at) unless dry_run
      item.update_column(:last_snapshot, serialized_snapshot(item)) if !dry_run && item.last_snapshot.blank?
      summary["items.#{identity[:service_type]}"] += 1
    end

    def backfill_collection(collection)
      confidence = collection.mapping_confidence.presence || "low"
      collection.sync_items.each { |item| backfill_membership(collection, item, confidence) }
    end

    def backfill_membership(collection, item, confidence)
      return skipped_mapping(confidence) if item.external_id.blank? || !PUBLISHED_CONFIDENCES.include?(confidence)

      ::Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: baseline_time(item)) unless dry_run
      summary["mappings.#{confidence}"] += 1
    end

    def enqueue_item(item, identity, observed_at)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, identity, observed_at),
        service_type: identity[:service_type], service_instance: identity[:service_instance],
        external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified, observed_at:
      )
    end

    def item_payload(item, identity, observed_at)
      serialized_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: timestamp(observed_at),
        source: identity,
        provenance: { detected_by: "backfill", baseline: true, backfilled_at: timestamp(observed_at) }
      )
    end

    def serialized_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? timestamp(value) : value }
    end

    def baseline_time(item)
      item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at || Time.current
    end

    def timestamp(time)
      time.utc.iso8601(6)
    end

    def skipped_item(item)
      summary["skipped.items.missing_external_id.#{item.provider.underscore}"] += 1
    end

    def skipped_mapping(confidence)
      summary["skipped.mappings.#{confidence}"] += 1
    end

    def print_summary
      output.puts "TaskBridge outbox backfill dry run"
      summary.sort.each { |key, count| output.puts "#{key}: #{count}" }
    end
  end
end
