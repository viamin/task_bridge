# frozen_string_literal: true

module Outbox
  class BaselineBackfill
    # Builds the baseline form of the RDR #215 item snapshot payload: the
    # item's normalized snapshot with timestamps rendered as ISO 8601 UTC
    # (so JSON round-trips stay diff-stable), the internal snapshot
    # `version` swapped for the contract's `contract_version`, the
    # membership block added when the mapping is published, and baseline
    # provenance so TaskBridge Web can tell a backfilled current-state row
    # from a live observation. Extra fields beyond the contract's minimum
    # are safe: version 1 consumers must ignore unknown fields.
    class ItemPayload
      def self.build(item, observed_at:, backfilled_at:, membership_block:)
        new(item, observed_at:, backfilled_at:, membership_block:).build
      end

      def initialize(item, observed_at:, backfilled_at:, membership_block:)
        @item = item
        @observed_at = observed_at
        @backfilled_at = backfilled_at
        @membership_block = membership_block
      end

      def build
        iso_snapshot.except(:version).merge(
          contract_version: OutboxEntry::PAYLOAD_VERSION,
          observed_at: iso(@observed_at),
          provenance: {
            detected_by: BaselineBackfill::DETECTED_BY,
            backfilled_at: iso(@backfilled_at)
          }
        ).tap { |payload| payload[:sync_collection] = @membership_block if @membership_block }
      end

      private

      def iso_snapshot
        @item.normalized_snapshot.deep_transform_values do |value|
          value.respond_to?(:utc) ? iso(value) : value
        end
      end

      def iso(time)
        time.utc.iso8601(6)
      end
    end
  end
end
