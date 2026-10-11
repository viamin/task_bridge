# frozen_string_literal: true

module Outbox
  # Seeds the outbox with a current-state item snapshot without inventing a
  # historical observation.  The same normalized snapshot also becomes the
  # comparison baseline for the next live refresh.
  class BaselineSnapshot
    BACKFILL_DETECTED_BY = "backfill"

    def self.emit_for(item, observed_at:)
      return if item.external_id.blank?

      new(item, observed_at:).emit
    end

    def initialize(item, observed_at:)
      @item = item
      @observed_at = observed_at
    end

    def emit
      OutboxEntry.enqueue(record_kind: :item, payload:, **context)
      item.update_column(:last_snapshot, snapshot) if item.last_snapshot.blank?
    end

    private

    attr_reader :item, :observed_at

    def payload
      snapshot.merge(
        observed_at: iso_timestamp(observed_at),
        provenance: { detected_by: BACKFILL_DETECTED_BY, backfilled_at: iso_timestamp(Time.current) }
      )
    end

    def snapshot
      @snapshot ||= item.normalized_snapshot.deep_transform_values do |value|
        value.respond_to?(:utc) ? iso_timestamp(value) : value
      end
    end

    def context
      identity = Outbox::SourceIdentity.for(item)
      {
        service_type: identity[:service_type], service_instance: identity[:service_instance],
        external_id: identity[:external_id], sync_collection_id: item.sync_collection_id,
        source_updated_at: item.source_updated_at || item.last_modified, observed_at:
      }
    end

    def iso_timestamp(time)
      time.utc.iso8601(6)
    end
  end
end
