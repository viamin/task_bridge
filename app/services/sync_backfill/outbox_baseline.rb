# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from records that existed
  # before observation publication was enabled. These rows are intentionally
  # snapshots, not historical observation events.
  class OutboxBaseline
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, now: Time.current, output: $stdout)
      new(dry_run:, now:, output:).run!
    end

    def initialize(dry_run:, now:, output:)
      @dry_run = dry_run
      @now = now
      @output = output
      @summary = Hash.new(0)
      @summary[:services] = Hash.new(0)
      @summary[:mapping_confidence] = Hash.new(0)
      @summary[:skipped] = Hash.new(0)
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      output.puts(JSON.generate(summary))
      summary
    end

    private

    attr_reader :dry_run, :now, :output, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        identity = Outbox::SourceIdentity.for(item)
        if identity[:external_id].blank?
          summary[:skipped]["items_missing_external_id"] += 1
          next
        end

        summary[:services][identity[:service_type]] += 1
        summary[:item_snapshots] += 1
        enqueue_item(item, identity) unless dry_run
      end
    end

    def enqueue_item(item, identity)
      observed_at = baseline_time_for(item)
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
      item.normalized_snapshot.deep_stringify_keys.merge(
        "contract_version" => OutboxEntry::PAYLOAD_VERSION,
        "observed_at" => iso_timestamp(observed_at),
        "provenance" => {
          "detected_by" => "backfill",
          "backfilled_at" => iso_timestamp(now)
        }
      )
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence.presence || "low"
        summary[:mapping_confidence][confidence] += collection.sync_items.size
        unless PUBLISHABLE_CONFIDENCES.include?(confidence)
          summary[:skipped]["low_confidence_mappings"] += collection.sync_items.size
          next
        end

        summary[:mapping_rows] += collection.sync_items.count { |item| item.external_id.present? }
        next if dry_run

        Outbox::MappingEmitter.emit_for_members(
          collection,
          members: collection.sync_items,
          observed_at: baseline_time_for(collection)
        )
      end
    end

    def baseline_time_for(record)
      record.try(:first_observed_at) || record.try(:mapping_established_at) ||
        record.updated_at || record.created_at || now
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
