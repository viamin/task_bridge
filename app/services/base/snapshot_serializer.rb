# frozen_string_literal: true

module Base
  # Builds a deterministic, versioned, source-agnostic snapshot of a
  # Base::SyncItem's current state. This is the shared shape that change
  # detection and the eventual TaskBridge Web publisher can consume without
  # branching on the source service (see
  # docs/rdr-215-taskbridge-observation-publication-contract.md and
  # docs/normalized-snapshot-field-support.md).
  #
  # Fields common to multiple adapters are promoted to the top level via
  # duck-typed optional reads. Everything else belongs under `metadata`,
  # which each SyncItem subclass supplies through its own
  # `normalized_metadata` override.
  class SnapshotSerializer
    VERSION = 1

    def self.call(item)
      new(item).call
    end

    def initialize(item)
      @item = item
    end

    def call
      identity_fields
        .merge(lifecycle_fields)
        .merge(scheduling_fields)
        .merge(classification_fields)
        .merge(relationship_fields)
        .merge(metadata: item.normalized_metadata)
    end

    private

    attr_reader :item

    def identity_fields
      {
        version: VERSION,
        item_key: item.item_key,
        entity_type: "task",
        source: source_identity,
        sync_collection_id: item.sync_collection_id,
        observed_at: item.last_observed_at
      }
    end

    def source_identity
      {
        # The publication contract (#215) calls for stable adapter-family
        # identifiers (e.g. "asana", "google_tasks") rather than the display
        # names each subclass's `provider` returns ("Asana", "GoogleTasks").
        service_type: Base::Service.service_identifier_for(item.provider),
        service_instance: item.source_service_instance,
        external_id: item.source_external_id.presence || item.external_id,
        source_url: item.source_url.presence || item.url
      }
    end

    def lifecycle_fields
      {
        title: item.title,
        display_title: item.friendly_title,
        # Notes are intentionally omitted: the publication contract (#215)
        # requires `notes_preview` to be opt-in per source via TaskBridge
        # configuration, and the per-source setting does not exist yet.
        # Until then, emitting full notes here would silently leak source
        # notes to any consumer of this snapshot. When the setting lands,
        # gate this field behind it (as `notes_preview`, not `notes`).
        status: status,
        completed: item.completed?,
        completed_at: item.completed_at || item.completed_on,
        # SyncItem does not yet model explicit deletion; snapshots are only
        # ever built for items TaskBridge still observes.
        is_deleted: false
      }
    end

    # No current adapter exposes a "dropped" (explicitly abandoned) state,
    # so this only ever yields "open" or "completed" today. The branch is
    # kept so a future adapter (e.g. OmniFocus's dropped tasks) can opt in
    # without changing this method's contract.
    def status
      return "dropped" if item.respond_to?(:dropped?) && item.dropped?
      return "completed" if item.completed?

      "open"
    end

    def scheduling_fields
      {
        due_at: item.due_at,
        due_date: item.due_date,
        start_at: item.start_at,
        start_date: item.start_date,
        source_created_at: item.source_created_at,
        source_updated_at: item.source_updated_at
      }
    end

    def classification_fields
      {
        flagged: item.flagged,
        priority: optional(:priority),
        estimated_minutes: optional(:estimated_minutes),
        project: optional(:project),
        tags: Array(item.tags),
        assignee: optional(:assignee)
      }
    end

    def relationship_fields
      {
        parent_item_id: item.parent_item_id,
        sub_item_count: optional(:sub_item_count),
        sub_item_keys: sub_item_keys
      }
    end

    def sub_item_keys
      return unless item.respond_to?(:sub_items)

      Array(item.sub_items).filter_map { |sub_item| sub_item.try(:item_key) }
    end

    def optional(attribute)
      item.public_send(attribute) if item.respond_to?(attribute)
    end
  end
end
