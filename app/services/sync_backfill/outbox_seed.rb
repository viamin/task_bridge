# frozen_string_literal: true

module SyncBackfill
  # Builds a safe initial outbox baseline from already-synchronized records.
  # The stable first-observed/mapping-established timestamps make retries and
  # later invocations idempotent through OutboxEntry's unique key.
  class OutboxSeed
    def self.run!
      new.run!
    end

    def self.preview
      new.preview
    end

    def run!
      SourceProvenance.run!
      seed_items
      seed_mappings
      summary
    end

    def preview
      summarize_items
      summarize_mappings
      summary
    end

    private

    attr_reader :counts

    def initialize
      @counts = Hash.new(0)
      @services = Hash.new(0)
      @confidences = Hash.new(0)
    end

    def seed_items
      Base::SyncItem.find_each { |item| seed_item(item) }
    end

    def seed_item(item)
      return skipped_item(item) if item.external_id.blank?

      Outbox::ItemSnapshotEmitter.emit_baseline_for(item, observed_at: item_observed_at(item))
      record_item(item)
    end

    def seed_mappings
      SyncCollection.includes(:sync_items).find_each { |collection| seed_mapping(collection) }
    end

    def seed_mapping(collection)
      return skipped_mapping(collection) unless publishable_mapping?(collection)

      members = collection.sync_items.to_a
      Outbox::MappingEmitter.emit_baseline_for_members(collection, members:, observed_at: mapping_observed_at(collection))
      record_mapping(collection, members)
    end

    def summarize_items
      Base::SyncItem.find_each { |item| item.external_id.present? ? record_item(item) : skipped_item(item) }
    end

    def summarize_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        publishable_mapping?(collection) ? record_mapping(collection, collection.sync_items.to_a) : skipped_mapping(collection)
      end
    end

    def record_item(item)
      @counts[:item_snapshots] += 1
      @services[Outbox::SourceIdentity.for(item).fetch(:service_type)] += 1
    end

    def record_mapping(collection, members)
      @counts[:mapping_memberships] += members.count { |item| item.external_id.present? }
      @confidences[collection.mapping_confidence] += members.count
    end

    def skipped_item(item)
      @counts[:items_missing_external_id] += 1
      @services[Outbox::SourceIdentity.for(item).fetch(:service_type)] += 1
    end

    def skipped_mapping(collection)
      @counts[:mappings_withheld] += collection.sync_items.count
      @confidences[collection.mapping_confidence || "unknown"] += collection.sync_items.count
    end

    def publishable_mapping?(collection)
      %w[high medium].include?(collection.mapping_confidence)
    end

    def item_observed_at(item)
      item.first_observed_at || item.created_at || item.updated_at
    end

    def mapping_observed_at(collection)
      collection.mapping_established_at || collection.created_at || collection.updated_at
    end

    def summary
      {
        items: @counts[:item_snapshots],
        mappings: @counts[:mapping_memberships],
        skipped: {
          incomplete_items: @counts[:items_missing_external_id],
          withheld_low_confidence_mappings: @counts[:mappings_withheld]
        },
        by_service: @services.sort.to_h,
        by_confidence: @confidences.sort.to_h
      }
    end
  end
end
