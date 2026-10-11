# frozen_string_literal: true

module SyncBackfill
  # Baseline `item` outbox rows for existing sync_items (#222), so
  # TaskBridge Web can seed its current-state view from already-synced
  # local data without treating it as historical change history. Reuses
  # Outbox::ItemSnapshotEmitter, which marks every row
  # `provenance.detected_by: "backfill"`.
  #
  # Idempotent: the per-item idempotency key is derived from the item's
  # existing last_observed_at (not the backfill's run time), so rerunning
  # finds the same key and leaves the stored row untouched
  # (OutboxEntry.enqueue is create_or_find_by).
  class BaselineSnapshots
    def self.summary
      new.summary
    end

    def self.run!
      new.run!
    end

    def summary
      tally { |_item| nil }
    end

    def run!
      tally { |item| Outbox::ItemSnapshotEmitter.emit_for_item(item, backfilled_at:) }
    end

    private

    def backfilled_at
      @backfilled_at ||= Time.current
    end

    def tally
      by_service = Hash.new(0)
      skipped = []
      Base::SyncItem.find_each do |item|
        next skipped << { id: item.id, reason: skip_reason(item) } unless eligible?(item)

        by_service[service_bucket(item)] += 1
        yield item
      end
      { by_service:, enqueued: by_service.values.sum, skipped: }
    end

    def eligible?(item)
      item.external_id.present? && item.source_service_name.present?
    end

    def skip_reason(item)
      return "missing_external_id" if item.external_id.blank?

      "missing_source_identity"
    end

    def service_bucket(item)
      Base::Service.service_identifier_for(item.source_service_name)
    end
  end
end
