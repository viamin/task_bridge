# frozen_string_literal: true

module Outbox
  # Builds the RDR #215 minimum item snapshot payload — the current-state
  # document for a source item — from a persisted Base::SyncItem. Unlike
  # Base::SnapshotSerializer (the diff-oriented snapshot used by the live
  # observation pipeline), this builder only states facts persisted in
  # local columns: the baseline backfill (#222) runs against rows loaded
  # from the database, where per-provider readers (tags, external payload
  # metadata) are not available, so it never claims facts it cannot know.
  # Fields the live pipeline will publish on the next sync — tags, parent
  # references, source_metadata — are omitted rather than guessed, and
  # version 1 consumers must ignore unknown fields anyway.
  class ItemSnapshot
    def self.for(item, observed_at:, provenance:)
      new(item, observed_at:, provenance:).payload
    end

    def initialize(item, observed_at:, provenance:)
      @item = item
      @observed_at = observed_at
      @provenance = provenance
    end

    def payload
      {
        contract_version: OutboxEntry::PAYLOAD_VERSION,
        item_key: item.item_key,
        entity_type: "task",
        observed_at: iso_timestamp(observed_at),
        title: item.title,
        status: status,
        is_deleted: false,
        completed_at: iso_timestamp(item.completed_at || item.completed_on),
        source_created_at: iso_timestamp(item.source_created_at),
        source_updated_at: iso_timestamp(item.source_updated_at || item.last_modified),
        due_at: iso_timestamp(item.due_at || item.due_date),
        started_at: iso_timestamp(item.start_at || item.start_date),
        source: Outbox::SourceIdentity.for(item),
        provenance:
      }
    end

    private

    attr_reader :item, :observed_at, :provenance

    # Mirrors Base::SnapshotSerializer#status. No current adapter models a
    # dropped state on persisted rows, so this yields open/completed today;
    # the branch is kept so a future adapter can opt in without changing
    # the payload contract.
    def status
      return "dropped" if item.respond_to?(:dropped?) && item.dropped?
      return "completed" if item.completed?

      "open"
    end

    def iso_timestamp(time)
      time&.utc&.iso8601(6)
    end
  end
end
