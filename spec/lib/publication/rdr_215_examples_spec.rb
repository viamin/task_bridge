# frozen_string_literal: true

require "rails_helper"

# Locks the JSON examples published in RDR 215 to the contract implementation.
#
# The per-class specs cover every validation rule in isolation; this file
# verifies the documented examples end to end so the RDR and the code cannot
# drift apart silently: editing either side breaks the matching example here.
RSpec.describe "RDR 215 contract examples" do
  describe "idempotency keys" do
    it "reproduces the documented item snapshot key" do
      key = Publication::IdempotencyKey.for_item(
        service_instance: "asana:workspace-12345:default",
        external_id: "1201234567890",
        observed_at: "2026-08-14T19:20:31.123456Z"
      )
      expect(key).to eq("tb:v1:item:asana:workspace-12345:default:1201234567890:snapshot:2026-08-14T19:20:31.123456Z")
    end

    it "reproduces the documented observation key" do
      key = Publication::IdempotencyKey.for_observation(
        service_instance: "asana:workspace-12345:default",
        external_id: "1201234567890",
        event_type: "source_changed",
        observed_at: "2026-08-14T19:20:31.123456Z"
      )
      expect(key).to eq("tb:v1:obs:asana:workspace-12345:default:1201234567890:source_changed:2026-08-14T19:20:31.123456Z")
    end

    it "reproduces the documented mapping key" do
      key = Publication::IdempotencyKey.for_mapping(
        sync_collection_id: 84,
        service_instance: "asana:workspace-12345:default",
        external_id: "1201234567890",
        observed_at: "2026-08-14T19:21:00.000000Z"
      )
      expect(key).to eq("tb:v1:map:sync_collection:84:membership:asana:workspace-12345:default:1201234567890:2026-08-14T19:21:00.000000Z")
    end

    it "reproduces the documented sync-run key" do
      key = Publication::IdempotencyKey.for_sync_run(
        service_instance: "asana:workspace-12345:default",
        sync_run_id: "sync-run-20260814T192000Z-asana"
      )
      expect(key).to eq("tb:v1:sync_run:asana:workspace-12345:default:sync-run-20260814T192000Z-asana")
    end
  end

  describe "the item snapshot example" do
    it "round-trips through ItemSnapshot with canonical timestamps" do
      snapshot = Publication::ItemSnapshot.new(
        idempotency_key: "tb:v1:item:asana:workspace-12345:default:1201234567890:snapshot:2026-08-14T19:20:31.123456Z",
        item_key: "asana:workspace-12345:default:1201234567890",
        observed_at: "2026-08-14T19:20:31.123456Z",
        title: "Buy milk",
        status: "open",
        is_deleted: false,
        completed_at: nil,
        source_created_at: "2026-08-10T12:00:00Z",
        source_updated_at: "2026-08-14T18:58:02Z",
        due_at: "2026-08-15T17:00:00Z",
        started_at: nil,
        notes_preview: "2% and eggs",
        tags: %w[Errands Home],
        parent: { external_id: nil, item_key: nil },
        source: {
          service_type: "asana",
          service_instance: "asana:workspace-12345:default",
          external_id: "1201234567890",
          source_url: "https://app.asana.com/0/12345/1201234567890",
          source_collection_keys: [{ kind: "project", id: "project-9" }, { kind: "section", id: "section-3" }]
        },
        sync_collection: {
          sync_collection_id: 84,
          membership_role: "member",
          mapping_confidence: "confirmed",
          mapping_source: "sync_id_note"
        },
        source_metadata: { item_type: "task" }
      )

      payload = snapshot.to_payload
      expect(payload[:entity_type]).to eq("task")
      expect(payload[:source_created_at]).to eq("2026-08-10T12:00:00.000000Z")
      expect(payload[:due_at]).to eq("2026-08-15T17:00:00.000000Z")
      expect(payload[:notes_preview]).to eq("2% and eggs")
      expect(payload[:source][:source_collection_keys]).to eq([{ kind: "project", id: "project-9" }, { kind: "section", id: "section-3" }])
      expect(payload[:sync_collection][:mapping_confidence]).to eq("confirmed")
    end
  end

  describe "the source_changed observation example" do
    it "round-trips through Observation" do
      observation = Publication::Observation.new(
        idempotency_key: "tb:v1:obs:asana:workspace-12345:default:1201234567890:source_changed:2026-08-14T19:20:31.123456Z",
        event_type: "source_changed",
        observed_at: "2026-08-14T19:20:31.123456Z",
        published_at: "2026-08-14T19:20:33.000000Z",
        item_key: "asana:workspace-12345:default:1201234567890",
        source: {
          service_type: "asana",
          service_instance: "asana:workspace-12345:default",
          external_id: "1201234567890",
          source_url: "https://app.asana.com/0/12345/1201234567890"
        },
        change: { field: "status", from: "open", to: "completed" },
        source_created_at: "2026-08-10T12:00:00Z",
        source_updated_at: "2026-08-14T19:19:58Z",
        completed_at: "2026-08-14T19:19:58Z",
        provenance: { detected_by: "sync_compare", sync_run_id: "sync-run-20260814T192000Z-asana" }
      )

      payload = observation.to_payload
      expect(payload[:change]).to eq({ field: "status", from: "open", to: "completed" })
      expect(payload[:published_at]).to eq("2026-08-14T19:20:33.000000Z")
      expect(payload[:provenance][:detected_by]).to eq("sync_compare")
    end
  end

  describe "the tombstone example" do
    it "round-trips through Observation with last_known and is_deleted" do
      tombstone = Publication::Observation.new(
        idempotency_key: "tb:v1:obs:omnifocus:default:task-77:deleted:2026-08-14T19:30:00.000000Z",
        event_type: "deleted",
        observed_at: "2026-08-14T19:30:00.000000Z",
        published_at: "2026-08-14T19:30:01.000000Z",
        item_key: "omnifocus:default:task-77",
        source: {
          service_type: "omnifocus",
          service_instance: "omnifocus:default",
          external_id: "task-77",
          source_url: "omnifocus:///task/task-77"
        },
        last_known: { title: "Buy milk", status: "open" },
        is_deleted: true,
        provenance: { detected_by: "missing_from_authoritative_fetch", sync_run_id: "sync-run-20260814T192500Z-omnifocus" }
      )

      payload = tombstone.to_payload
      expect(payload[:is_deleted]).to be true
      expect(payload[:last_known]).to eq({ title: "Buy milk", status: "open" })
    end
  end

  describe "the mapping example" do
    it "round-trips through Mapping" do
      mapping = Publication::Mapping.new(
        idempotency_key: "tb:v1:map:sync_collection:84:membership:github:repo-1:issue-42:2026-08-14T19:21:00.000000Z",
        mapping_type: "representation_membership",
        observed_at: "2026-08-14T19:21:00.000000Z",
        sync_collection: { sync_collection_id: 84, title: "Release checklist" },
        member: {
          item_key: "github:repo-1:issue-42",
          service_type: "github",
          service_instance: "github:repo-1",
          external_id: "issue-42"
        },
        membership_role: "member",
        mapping_confidence: "tentative",
        mapping_source: "title_match",
        provenance: { matched_fields: ["title"], notes: "Single-title match during sync" }
      )

      payload = mapping.to_payload
      expect(payload[:sync_collection]).to eq({ sync_collection_id: 84, title: "Release checklist" })
      expect(payload[:member][:external_id]).to eq("issue-42")
      expect(payload[:mapping_confidence]).to eq("tentative")
    end
  end

  describe "the sync-run summary examples" do
    it "round-trips the success example through SyncRunSummary" do
      summary = Publication::SyncRunSummary.new(
        idempotency_key: "tb:v1:sync_run:asana:workspace-12345:default:sync-run-20260814T192000Z-asana",
        sync_run_id: "sync-run-20260814T192000Z-asana",
        service_type: "asana",
        service_instance: "asana:workspace-12345:default",
        started_at: "2026-08-14T19:20:00.000000Z",
        finished_at: "2026-08-14T19:21:05.000000Z",
        last_attempted_at: "2026-08-14T19:20:00.000000Z",
        last_successful_at: "2026-08-14T19:21:05.000000Z",
        status: "success",
        items_synced: 12,
        touched_collection_ids: [84, 91],
        detail: "12 items processed"
      )

      payload = summary.to_payload
      expect(payload[:touched_collection_ids]).to eq([84, 91])
      expect(payload[:detail]).to eq("12 items processed")
    end

    it "round-trips the failure example through SyncRunSummary" do
      summary = Publication::SyncRunSummary.new(
        idempotency_key: "tb:v1:sync_run:github:repo-1:sync-run-20260814T193000Z-github",
        sync_run_id: "sync-run-20260814T193000Z-github",
        service_type: "github",
        service_instance: "github:repo-1",
        started_at: "2026-08-14T19:30:00.000000Z",
        finished_at: "2026-08-14T19:30:02.000000Z",
        last_attempted_at: "2026-08-14T19:30:00.000000Z",
        last_failed_at: "2026-08-14T19:30:02.000000Z",
        status: "failed",
        items_synced: 0,
        touched_collection_ids: [],
        detail: "ProviderError: 401 unauthorized",
        error: { class: "ProviderError", message: "401 unauthorized", retryable: false }
      )

      payload = summary.to_payload
      expect(payload[:error]).to eq({ class: "ProviderError", message: "401 unauthorized", retryable: false })
    end
  end
end
