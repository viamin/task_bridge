# frozen_string_literal: true

module SyncBackfill
  # Seeds TaskBridge Web's current-state projection from existing local sync
  # data. These are deliberately item snapshots, not historical observations.
  class ObservationBaseline
    def self.run!(dry_run: false, output: $stdout)
      new(dry_run:, output:).run!
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @summary = Summary.new
    end

    def run!
      SourceProvenance.run! unless dry_run
      backfill_items
      backfill_mappings
      output.puts(JSON.generate(summary.to_h)) if dry_run
      summary.to_h
    end

    private

    attr_reader :dry_run, :output, :summary

    def backfill_items
      Base::SyncItem.find_each do |item|
        unless item.external_id.present?
          summary.skip_item(item, "missing_external_id")
          next
        end

        identity = Outbox::SourceIdentity.for(item)
        summary.add_item(identity[:service_type])
        enqueue_item(item, identity) unless dry_run
      end
    end

    def enqueue_item(item, identity)
      observed_at = item.last_observed_at || item.updated_at || item.created_at
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: item_payload(item, identity, observed_at),
        service_type: identity[:service_type],
        service_instance: identity[:service_instance],
        external_id: identity[:external_id],
        sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified,
        observed_at:
      )
    end

    def item_payload(item, identity, observed_at)
      item.normalized_snapshot.except(:version).merge(
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        observed_at: observed_at.utc.iso8601(6),
        source: identity,
        provenance: {
          detected_by: "backfill",
          baseline: true,
          backfilled_at: Time.current.utc.iso8601(6)
        }
      )
    end

    def backfill_mappings
      SyncCollection.includes(:sync_items).find_each do |collection|
        collection.sync_items.each { |item| backfill_mapping(collection, item) }
      end
    end

    def backfill_mapping(collection, item)
      identity = Outbox::SourceIdentity.for(item)
      unless item.external_id.present?
        summary.skip_mapping(identity[:service_type], "missing_external_id")
        return
      end

      confidence = collection.mapping_confidence
      if confidence == "low"
        summary.withhold_mapping(identity[:service_type], confidence)
        return
      end
      unless %w[high medium].include?(confidence)
        summary.skip_mapping(identity[:service_type], "missing_or_unknown_confidence")
        return
      end

      summary.add_mapping(identity[:service_type], confidence)
      return if dry_run

      observed_at = collection.mapping_last_observed_at || item.last_observed_at || collection.updated_at
      Outbox::MappingEmitter.emit_for_members(collection, members: [item], observed_at:)
    end

    # Keeps the dry-run result useful to an operator while remaining compact
    # enough to be emitted as one machine-readable line from the Rake task.
    class Summary
      def initialize
        @items = Hash.new(0)
        @mappings = Hash.new { |hash, key| hash[key] = Hash.new(0) }
        @withheld = Hash.new { |hash, key| hash[key] = Hash.new(0) }
        @skipped = Hash.new { |hash, key| hash[key] = Hash.new(0) }
      end

      def add_item(service)
        @items[service] += 1
      end

      def add_mapping(service, confidence)
        @mappings[service][confidence] += 1
      end

      def withhold_mapping(service, confidence)
        @withheld[service][confidence] += 1
      end

      def skip_item(item, reason)
        @skipped[service_for(item)][reason] += 1
      end

      def skip_mapping(service, reason)
        @skipped[service][reason] += 1
      end

      def to_h
        {
          items_by_service: @items,
          mappings_by_service_and_confidence: @mappings,
          withheld_mappings_by_service_and_confidence: @withheld,
          skipped_or_incomplete_by_service_and_reason: @skipped
        }
      end

      private

      def service_for(item)
        Base::Service.service_identifier_for(item.provider)
      end
    end
  end
end
