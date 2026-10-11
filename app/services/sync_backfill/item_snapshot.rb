# frozen_string_literal: true

require "openssl"

module SyncBackfill
  # Builds the baseline `item` outbox row backfill (#222) enqueues for each
  # existing Base::SyncItem so TaskBridge Web can seed current state before
  # the live observation pipeline (#219-#221) starts reporting changes.
  #
  # Deliberately does not reuse Base::SnapshotSerializer/normalized_snapshot:
  # several adapters' `normalized_metadata` (e.g. Github::Issue, GoogleKeep::Item)
  # dereference a transient per-fetch ivar (`github_issue`, `keep_item`) that
  # is only populated right after a live `read_original`, and is nil for a
  # row loaded cold from the database, which is exactly backfill's case. This
  # builds the payload only from persisted columns, which is also the more
  # honest baseline: backfill never calls out to a source API (acceptance
  # criterion: "does not mutate external source systems").
  module ItemSnapshot
    module_function

    def eligible?(item)
      item.persisted? && item.external_id.present?
    end

    def observed_at_for(item)
      item.last_observed_at || item.updated_at || item.created_at || Time.current
    end

    def enqueue(item, identity:, backfilled_at:)
      observed_at = observed_at_for(item)
      Outbox::IsolatedWrite.call("backfill item snapshot for #{item.item_key}") do
        OutboxEntry.enqueue(
          record_kind: :item,
          payload: payload(item, identity, observed_at, backfilled_at),
          service_type: identity[:service_type],
          service_instance: identity[:service_instance],
          external_id: identity[:external_id],
          sync_collection_id: item.sync_collection_id,
          source_updated_at: item.source_updated_at || item.last_modified,
          observed_at:
        )
      end
    end

    def payload(item, identity, observed_at, backfilled_at)
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        item_key: item.item_key,
        entity_type: "task",
        observed_at: iso(observed_at),
        title: item.title,
        status: status_for(item),
        is_deleted: false,
        completed_at: iso(item.completed_at || item.completed_on),
        source_created_at: iso(item.source_created_at),
        source_updated_at: iso(item.source_updated_at || item.last_modified),
        due_at: iso(item.due_at),
        started_at: iso(item.start_at),
        tags: Array(item.tags),
        notes_digest: notes_digest_for(item),
        parent_item_id: item.parent_item_id,
        sync_collection_id: item.sync_collection_id,
        source: identity,
        provenance: { detected_by: "backfill" },
        backfilled_at: iso(backfilled_at)
      }
    end

    def status_for(item)
      return "dropped" if item.respond_to?(:dropped?) && item.dropped?
      return "completed" if item.completed?

      "open"
    end

    def notes_digest_for(item)
      content = item.notes_content.to_s if item.respond_to?(:notes_content)
      OpenSSL::HMAC.hexdigest("SHA256", TaskBridge.digest_key, content) if content.present?
    end

    def iso(time)
      time&.utc&.iso8601(6)
    end
  end
end
