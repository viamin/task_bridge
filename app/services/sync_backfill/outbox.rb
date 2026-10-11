# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from data that existed
  # before the outbox was introduced. It deliberately emits item snapshots,
  # not historical observation events or guessed sync runs.
  class Outbox
    PUBLISHED_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @summary = {
        items: Hash.new(0),
        mappings: Hash.new(0),
        withheld_mappings: Hash.new(0),
        skipped: Hash.new(0)
      }
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :dry_run, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary[:skipped][:missing_external_id] += 1
          next
        end

        observed_at = item.last_observed_at || item.updated_at || item.created_at
        if observed_at.blank?
          summary[:skipped][:missing_observed_at] += 1
          next
        end

        summary[:items][::Outbox::SourceIdentity.for(item)[:service_type]] += 1
        enqueue_item(item, observed_at:) unless dry_run
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence
        members, incomplete_members = collection.sync_items.partition { |item| item.external_id.present? }
        summary[:skipped][:mapping_missing_external_id] += incomplete_members.size if incomplete_members.any?
        if PUBLISHED_CONFIDENCES.exclude?(confidence)
          summary[:withheld_mappings][confidence.presence || "unknown"] += members.size
          next
        end

        observed_at = mapping_observed_at(collection)
        members.each do |member|
          summary[:mappings][confidence] += 1
          ::Outbox::MappingEmitter.emit_for_members(collection, members: [member], observed_at:) unless dry_run
        end
      end
    end

    def enqueue_item(item, observed_at:)
      identity = ::Outbox::SourceIdentity.for(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, observed_at:),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def item_payload(item, observed_at:)
      item.normalized_snapshot.deep_transform_values { |value| iso_timestamp(value) }.merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(observed_at),
        provenance: {
          detected_by: "backfill",
          baseline: true,
          backfilled_at: iso_timestamp(observed_at)
        }
      )
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.mapping_established_at ||
        collection.updated_at || collection.created_at
    end

    def iso_timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value
    end
  end
end
