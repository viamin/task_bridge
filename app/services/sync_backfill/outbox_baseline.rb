# frozen_string_literal: true

module SyncBackfill
  # Seeds the publication outbox from current local state.  These are
  # deliberately snapshots, not historical observations: live syncs own
  # source_changed history after this baseline has been established.
  class OutboxBaseline
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
      @summary = {
        items_by_service: Hash.new(0),
        mappings_by_service: Hash.new(0),
        mappings_by_confidence: Hash.new(0),
        skipped: Hash.new(0)
      }
    end

    def run!
      SourceProvenance.run!(dry_run:)
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :dry_run, :now, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          summary[:skipped]["item_missing_external_id"] += 1
          next
        end

        identity = Outbox::SourceIdentity.for(item)
        summary[:items_by_service][identity[:service_type]] += 1
        next if dry_run

        observed_at = observed_at_for(item)
        entry = OutboxEntry.enqueue(record_kind: :item, payload: item_payload(item, observed_at),
                                    **item_context(identity, item, observed_at))
        item.update_column(:last_snapshot, published_snapshot(item)) if entry
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        summary[:mappings_by_confidence][collection.mapping_confidence.presence || "missing"] += collection.sync_items.size
        unless PUBLISHABLE_CONFIDENCES.include?(collection.mapping_confidence)
          summary[:skipped]["mapping_#{collection.mapping_confidence.presence || 'missing'}_confidence"] += collection.sync_items.size
          next
        end

        collection.sync_items.each do |item|
          if item.external_id.blank?
            summary[:skipped]["mapping_missing_external_id"] += 1
            next
          end

          identity = Outbox::SourceIdentity.for(item)
          summary[:mappings_by_service][identity[:service_type]] += 1
          Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at: mapping_observed_at(collection)) unless dry_run
        end
      end
    end

    def item_payload(item, observed_at)
      published_snapshot(item).merge(
        observed_at: iso_timestamp(observed_at),
        provenance: { detected_by: "backfill", backfilled_at: iso_timestamp(now) }
      )
    end

    def item_context(identity, item, observed_at)
      identity.slice(:service_type, :service_instance, :external_id).merge(
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def observed_at_for(record)
      record.last_observed_at || record.updated_at || record.created_at || now
    end

    def mapping_observed_at(collection)
      collection.mapping_last_observed_at || collection.updated_at || collection.created_at || now
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
