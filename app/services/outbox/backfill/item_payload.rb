# frozen_string_literal: true

module Outbox
  class Backfill
    # Shapes one persisted item's normalized snapshot into the RDR #215
    # item snapshot payload: contract-required fields under their contract
    # names (`started_at`, `source_metadata`) plus TaskBridge's optional
    # extras (`flagged`, `due_date`, `notes_digest`, ...), which version 1
    # consumers must ignore. The payload carries no note content — notes
    # stay behind the per-source export configuration, which does not
    # exist yet — and no `sync_collection` block: mapping facts publish
    # only through mapping rows, where low-confidence memberships are
    # withheld (#222).
    class ItemPayload
      def self.call(item, observed_at:, backfilled_at:)
        new(item, observed_at:, backfilled_at:).call
      end

      def initialize(item, observed_at:, backfilled_at:)
        @item = item
        @observed_at = observed_at
        @backfilled_at = backfilled_at
      end

      def call
        snapshot = item.normalized_snapshot
        {
          item_key: snapshot[:item_key],
          entity_type: snapshot[:entity_type],
          observed_at: iso(observed_at),
          title: snapshot[:title],
          status: snapshot[:status],
          is_deleted: snapshot[:is_deleted],
          completed_at: iso(snapshot[:completed_at]),
          source_created_at: iso(snapshot[:source_created_at]),
          source_updated_at: iso(snapshot[:source_updated_at]),
          due_at: iso(snapshot[:due_at]),
          due_date: iso(snapshot[:due_date]),
          started_at: iso(started_at(snapshot)),
          flagged: snapshot[:flagged],
          priority: snapshot[:priority],
          estimated_minutes: snapshot[:estimated_minutes],
          project: snapshot[:project],
          tags: snapshot[:tags],
          assignee: snapshot[:assignee],
          notes_digest: snapshot[:notes_digest],
          sub_item_count: snapshot[:sub_item_count],
          sub_item_keys: snapshot[:sub_item_keys],
          source: snapshot[:source],
          source_metadata: snapshot[:metadata].presence,
          provenance: provenance
        }
      end

      private

      attr_reader :item, :observed_at, :backfilled_at

      # The contract names the optional start field `started_at`; adapters
      # populate either the datetime (`start_at`) or date (`start_date`)
      # variant.
      def started_at(snapshot)
        snapshot[:start_at] || snapshot[:start_date]
      end

      def provenance
        {
          detected_by: Backfill::DETECTED_BY,
          backfilled_at: iso(backfilled_at),
          first_observed_at: iso(item.first_observed_at)
        }
      end

      def iso(time)
        time&.utc&.iso8601(6)
      end
    end
  end
end
