# frozen_string_literal: true

module Outbox
  # Emits `item` snapshot rows (RDR #215 "Minimum Normalized Item Snapshot
  # Schema") into the local outbox. The live sync flow publishes change
  # history as `observation` rows (#219); item rows carry current state, so
  # the #222 baseline backfill is today's producer. Payloads are marked with
  # provenance (`detected_by`/`backfilled_at`) so consumers can tell a
  # backfilled baseline snapshot apart from live observations without
  # mistaking it for a historical change event.
  class ItemSnapshotEmitter
    def self.emit_for_item(item, observed_at: nil, detected_by: nil, backfilled_at: nil)
      return unless eligible?(item)

      observed_at = observed_at || item.last_observed_at || Time.current
      identity = Outbox::SourceIdentity.for(item)
      OutboxEntry.enqueue(
        record_kind: :item,
        payload: payload(item, identity, observed_at, detected_by:, backfilled_at:),
        **enqueue_context(item, identity, observed_at)
      )
    end

    class << self
      private

      def eligible?(item)
        item.is_a?(Base::SyncItem) && item.persisted? && item.external_id.present?
      end

      # The item record is the normalized snapshot itself (RDR #215 required
      # fields — item_key, entity_type, title, status, is_deleted, source —
      # are all snapshot fields), with the contract envelope, the resolved
      # observation time, and the baseline provenance marker layered on top.
      def payload(item, identity, observed_at, detected_by:, backfilled_at:)
        published_snapshot(item, identity, observed_at)
          .merge(
            contract_version: OutboxEntry::PAYLOAD_VERSION,
            provenance: provenance(detected_by:, backfilled_at:)
          )
      end

      # Identical to Base::SyncItem#normalized_snapshot but with timestamps
      # rendered as ISO 8601 UTC so JSON round-trips keep microsecond
      # precision, and with the backfill's resolved observation time.
      def published_snapshot(item, identity, observed_at)
        item.normalized_snapshot
            .merge(source: identity, observed_at:)
            .deep_transform_values { |value| value.respond_to?(:utc) ? iso_timestamp(value) : value }
      end

      def provenance(detected_by:, backfilled_at:)
        {}.tap do |provenance|
          provenance[:detected_by] = detected_by if detected_by
          provenance[:backfilled_at] = iso_timestamp(backfilled_at) if backfilled_at
        end
      end

      def enqueue_context(item, identity, observed_at)
        {
          service_type: identity[:service_type],
          service_instance: identity[:service_instance],
          external_id: identity[:external_id],
          sync_collection_id: item.sync_collection_id,
          source_updated_at: item.source_updated_at || item.last_modified,
          observed_at:
        }
      end

      def iso_timestamp(time)
        time.utc.iso8601(6)
      end
    end
  end
end
