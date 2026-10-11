# frozen_string_literal: true

module SyncBackfill
  # Seeds the outbox from local sync state before TaskBridge Web publication is
  # enabled. It has no provider clients and never writes to external systems.
  class Outbox
    PUBLISHABLE_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false)
      new(dry_run:).run!
    end

    def initialize(dry_run:)
      @dry_run = dry_run
      @counts = Hash.new(0)
      @services = Hash.new(0)
      @confidences = Hash.new(0)
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      summary
    end

    private

    attr_reader :dry_run, :counts, :services, :confidences

    def backfill_items
      Base::SyncItem.find_each { |item| backfill_item(item) }
    end

    def backfill_item(item)
      identity = ::Outbox::SourceIdentity.for(item)
      return skip(:items, :missing_external_id) if identity[:external_id].blank?

      services[identity[:service_type]] += 1
      counts[:item_snapshots] += 1
      return if dry_run

      ::Outbox::ItemSnapshotEmitter.emit_for_backfill(item, observed_at: observed_at_for(item))
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each { |collection| backfill_mapping(collection) }
    end

    def backfill_mapping(collection)
      confidence = collection.mapping_confidence.presence || "low"
      confidences[confidence] += collection.sync_items.size
      return skip(:mappings, :low_confidence) unless PUBLISHABLE_CONFIDENCES.include?(confidence)

      members = collection.sync_items.select { |item| item.external_id.present? }
      skipped_members = collection.sync_items.size - members.size
      counts[:mapping_memberships] += members.size
      counts[:skipped_mappings_missing_external_id] += skipped_members
      return if dry_run

      ::Outbox::MappingEmitter.emit_for_members(collection, members:, observed_at: observed_at_for(collection))
    end

    def observed_at_for(record)
      record.try(:last_observed_at) || record.try(:mapping_last_observed_at) || record.updated_at || record.created_at
    end

    def skip(kind, reason)
      counts[:"skipped_#{kind}_#{reason}"] += 1
    end

    def summary
      {
        dry_run:,
        item_snapshots: counts[:item_snapshots],
        mapping_memberships: counts[:mapping_memberships],
        by_service: services.sort.to_h,
        by_confidence: confidences.sort.to_h,
        skipped: counts.filter_map { |key, value| [key, value] if key.to_s.start_with?("skipped_") }.to_h
      }
    end
  end
end
