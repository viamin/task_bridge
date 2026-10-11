# frozen_string_literal: true

module SyncBackfill
  # Creates a durable initial current-state view of existing local sync data.
  # It only writes TaskBridge's database; no source adapter is invoked.
  class OutboxBaseline
    PUBLISHED_CONFIDENCES = %w[high medium].freeze

    def self.run!(dry_run: false, now: Time.current)
      new(dry_run:, now:).run!
    end

    def initialize(dry_run:, now:)
      @dry_run = dry_run
      @now = now
      @summary = Hash.new(0)
      @services = Hash.new(0)
      @confidences = Hash.new(0)
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      result
    end

    private

    attr_reader :dry_run, :now, :summary, :services, :confidences

    def backfill_items
      Base::SyncItem.find_each do |item|
        unless item.external_id.present?
          summary[:items_skipped_incomplete] += 1
          next
        end

        identity = Outbox::SourceIdentity.for(item)
        services[identity[:service_type]] += 1
        summary[:items] += 1
        next if dry_run

        Outbox::ItemEmitter.emit_baseline_for(
          item,
          observed_at: item.last_observed_at || item.updated_at || now,
          backfilled_at: now
        )
      end
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        confidence = collection.mapping_confidence
        confidences[confidence || "unknown"] += 1
        if confidence.blank?
          summary[:mappings_skipped_incomplete] += 1
        elsif !PUBLISHED_CONFIDENCES.include?(confidence)
          summary[:mappings_withheld_low_confidence] += 1
        else
          summary[:mappings] += collection.sync_items.size
          unless dry_run
            Outbox::MappingEmitter.emit_for_members(
              collection,
              members: collection.sync_items,
              observed_at: collection.mapping_last_observed_at || now
            )
          end
        end
      end
    end

    def result
      summary.merge(services:, confidences:, dry_run:)
    end
  end
end
