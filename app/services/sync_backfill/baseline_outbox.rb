# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox with current state, not reconstructed history. The
  # timestamps come from existing local rows so a rerun produces the same
  # idempotency keys and never invents a later historical observation.
  class BaselineOutbox
    def self.run!
      new.run!
    end

    def self.dry_run
      new.dry_run
    end

    def run!
      SourceProvenance.run!
      generate(write: true)
    end

    def dry_run
      generate(write: false)
    end

    private

    def generate(write:)
      Base::SyncItem.find_each { |item| process_item(item, write:) }
      SyncCollection.includes(:sync_items).find_each { |collection| process_collection(collection, write:) }
      summary
    end

    def process_item(item, write:)
      return skip_item unless item.external_id.present?

      timestamp = item.first_observed_at || item.last_observed_at || item.updated_at || item.created_at
      identity = Outbox::SourceIdentity.for(item)
      count(:items, :ready, identity[:service_type])
      return unless write

      OutboxEntry.enqueue(record_kind: :item, payload: item_payload(item, identity, timestamp),
                          **item_context(item, identity, timestamp))
      establish_diff_baseline(item)
    end

    def process_collection(collection, write:)
      members = collection.sync_items.select { |item| item.external_id.present? }
      return skip_mapping(:incomplete) if members.empty?

      confidence = mapping_confidence(collection)
      return skip_mapping(:low_confidence) if confidence == "low"

      timestamp = collection.mapping_established_at || collection.mapping_last_observed_at ||
                  collection.updated_at || collection.created_at
      count(:mappings, :ready, confidence)
      return unless write

      Outbox::MappingEmitter.emit_for_members(
        collection,
        members:,
        observed_at: timestamp,
        baseline_metadata: { detected_by: "backfill", backfilled_at: iso_timestamp(timestamp) }
      )
    end

    def item_payload(item, identity, timestamp)
      published_snapshot(item).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: iso_timestamp(timestamp),
        source: identity,
        provenance: { detected_by: "backfill", backfilled_at: iso_timestamp(timestamp) }
      )
    end

    def mapping_confidence(collection)
      return collection.mapping_confidence if collection.mapping_confidence.present?

      SourceProvenance.inferred_mapping_provenance_for(collection).fetch(:confidence)
    end

    def item_context(item, identity, timestamp)
      {
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at: timestamp
      }
    end

    def establish_diff_baseline(item)
      return if item.last_snapshot.present?

      item.update_column(:last_snapshot, published_snapshot(item))
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? iso_timestamp(value) : value }
    end

    def iso_timestamp(timestamp)
      timestamp.utc.iso8601(6)
    end

    def skip_item
      count(:items, :skipped_incomplete, "unknown")
    end

    def skip_mapping(reason)
      count(:mappings, :"skipped_#{reason}", reason.to_s)
    end

    def count(section, outcome, group)
      summary[section][outcome] += 1
      summary[section][:by_group][group] += 1
    end

    def summary
      @summary ||= {
        items: { ready: 0, skipped_incomplete: 0, by_group: Hash.new(0) },
        mappings: { ready: 0, skipped_incomplete: 0, skipped_low_confidence: 0, by_group: Hash.new(0) },
        sync_runs: { skipped: "no reliable historical run timestamps" }
      }
    end
  end
end
