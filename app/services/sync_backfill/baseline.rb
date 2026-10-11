# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox from local sync state only. It never calls an adapter, so
  # it cannot update a provider while establishing the publication baseline.
  class Baseline
    def self.run!
      new.run!
    end

    def self.dry_run
      new.dry_run
    end

    def run!
      SourceProvenance.run!
      process_items(write: true)
      process_mappings(write: true)
      summary
    end

    def dry_run
      process_items(write: false)
      process_mappings(write: false)
      summary
    end

    private

    attr_reader :counts

    def initialize
      @counts = Hash.new(0)
    end

    def process_items(write:)
      Base::SyncItem.find_each do |item|
        if item.external_id.blank?
          counts[:items_skipped_incomplete] += 1
          next
        end

        observed_at = item.last_observed_at || item.updated_at || item.created_at
        key = item_key(item, observed_at)
        if OutboxEntry.exists?(idempotency_key: key)
          counts[:items_already_enqueued] += 1
        elsif write
          Outbox::ItemSnapshotEmitter.emit_baseline_for(item, observed_at:)
          item.update_column(:last_snapshot, published_snapshot(item)) if item.last_snapshot.blank?
          counts[service_count_key("items", item)] += 1
        else
          counts[service_count_key("items", item)] += 1
        end
      end
    end

    def process_mappings(write:)
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence
        unless %w[high medium].include?(confidence)
          counts[:"mappings_withheld_#{confidence || 'incomplete'}"] += collection.sync_items.length
          next
        end

        collection.sync_items.each do |item|
          if item.external_id.blank?
            counts[:mappings_skipped_incomplete] += 1
            next
          end

          observed_at = collection.mapping_last_observed_at || collection.updated_at || collection.created_at
          if OutboxEntry.exists?(idempotency_key: mapping_key(collection, item, observed_at))
            counts[:mappings_already_enqueued] += 1
          elsif write
            Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at:)
            counts[:"mappings_#{confidence}"] += 1
          else
            counts[:"mappings_#{confidence}"] += 1
          end
        end
      end
    end

    def item_key(item, observed_at)
      identity = Outbox::SourceIdentity.for(item)
      Outbox::IdempotencyKey.for(record_kind: :item, observed_at:, **identity)
    end

    def mapping_key(collection, item, observed_at)
      identity = Outbox::SourceIdentity.for(item)
      Outbox::IdempotencyKey.for(record_kind: :mapping, observed_at:, sync_collection_id: collection.id, **identity)
    end

    def published_snapshot(item)
      item.normalized_snapshot.deep_transform_values { |value| value.respond_to?(:utc) ? value.utc.iso8601(6) : value }
    end

    def service_count_key(prefix, item)
      :"#{prefix}_#{Outbox::SourceIdentity.for(item).fetch(:service_type)}"
    end

    def summary
      counts.merge(sync_runs_skipped: 0).sort.to_h
    end
  end
end
