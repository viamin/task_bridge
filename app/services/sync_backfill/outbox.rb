# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from records that existed
  # before outbox publication. It emits snapshots, never historical changes.
  class Outbox
    BACKFILL_DETECTED_BY = "backfill"
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @backfilled_at = Time.current
      @summary = Hash.new { |hash, key| hash[key] = Hash.new(0) }
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
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          skipped("missing_external_id", item)
          next
        end

        snapshot(item)
        summary[:items][service_type(item)] += 1
      end
    end

    def snapshot(item)
      return if dry_run?

      identity = ::Outbox::SourceIdentity.for(item)
      observed_at = observation_time_for(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: snapshot_payload(item),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def snapshot_payload(item)
      published_snapshot(item).merge(
        provenance: { detected_by: BACKFILL_DETECTED_BY },
        backfilled_at: timestamp(backfilled_at)
      )
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? timestamp(value) : value
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        members = collection.sync_items.to_a
        if PUBLISHABLE_CONFIDENCES.include?(collection.mapping_confidence)
          members.each { |member| mapping(member, collection) }
          emit_mappings(collection, members)
        else
          members.each { |member| skipped("low_confidence_mapping", member, collection.mapping_confidence || "unknown") }
        end
      end
    end

    def mapping(member, collection)
      return skipped("missing_external_id", member) if member.external_id.blank?

      summary["mappings_#{collection.mapping_confidence}"][service_type(member)] += 1
    end

    def emit_mappings(collection, members)
      return if dry_run?

      ::Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at: observation_time_for(collection))
    end

    def skipped(reason, item, confidence = nil)
      key = confidence ? "#{reason}:#{confidence}" : reason
      summary[:skipped]["#{key}:#{service_type(item)}"] += 1
    end

    def service_type(item)
      Base::Service.service_identifier_for(item.provider)
    end

    def observation_time_for(record)
      record.try(:last_observed_at) || record.try(:mapping_last_observed_at) ||
        record.updated_at || record.created_at || backfilled_at
    end

    def timestamp(time)
      time.utc.iso8601(6)
    end

    def dry_run?
      @dry_run
    end
  end
end
