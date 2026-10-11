# frozen_string_literal: true

module SyncBackfill
  class Baseline
    # Enqueues one baseline `item` snapshot row (RDR #215) per existing
    # sync item (#222). Rows are keyed deterministically on source
    # identity plus the item's last-observed timestamp, and items whose
    # identity already has an item row are skipped, so reruns are safe
    # no-ops even when items changed between runs. Items missing an
    # external_id (incomplete records) are counted as skipped instead of
    # failing the run.
    class ItemSnapshots
      def self.run!(dry_run: false, backfilled_at: Time.current, collection_facts: {})
        new(dry_run:, backfilled_at:, collection_facts:).run!
      end

      def initialize(dry_run:, backfilled_at:, collection_facts:)
        @dry_run = dry_run
        @backfilled_at = backfilled_at
        @collection_facts = collection_facts
        @considered = 0
        @enqueued = 0
        @by_service = Hash.new(0)
        @skipped = Hash.new(0)
      end

      def run!
        Base::SyncItem.includes(:sync_collection).find_each { |item| backfill_item(item) }
        {
          considered: @considered,
          enqueued: @enqueued,
          by_service: @by_service.sort.to_h,
          skipped: @skipped.sort.to_h
        }
      end

      private

      def backfill_item(item)
        @considered += 1
        if item.external_id.blank?
          @skipped["missing_external_id"] += 1
          return
        end

        identity = SyncBackfill::Baseline.identity_for(item)
        if already_backfilled?(identity)
          @skipped["already_backfilled"] += 1
          return
        end

        @enqueued += 1
        @by_service[identity[:service_type]] += 1
        return if @dry_run

        observed_at = item.last_observed_at || item.updated_at || item.created_at
        OutboxEntry.enqueue(
          record_kind: :item,
          payload: ItemPayload.for(item, identity:, observed_at:, backfilled_at: @backfilled_at,
                                         collection_facts: @collection_facts),
          service_type: identity[:service_type],
          service_instance: identity[:service_instance],
          external_id: identity[:external_id],
          sync_collection_id: item.sync_collection_id,
          observed_at:,
          source_updated_at: item.source_updated_at || item.last_modified
        )
      end

      def already_backfilled?(identity)
        existing_identities.include?([identity[:service_instance], identity[:external_id]])
      end

      def existing_identities
        @existing_identities ||= OutboxEntry.where(record_kind: "item")
                                            .pluck(:service_instance, :external_id).to_set
      end
    end
  end
end
