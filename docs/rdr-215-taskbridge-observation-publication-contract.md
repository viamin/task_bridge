# RDR 215: TaskBridge Observation and Publication Contract for TaskBridge Web

- Status: Accepted
- Date: 2026-08-14
- Issue: #215
- Parent: #214

## Summary

TaskBridge will publish normalized task facts to TaskBridge Web by HTTP push. TaskBridge remains responsible for detecting source observations during sync, normalizing them, and retrying delivery from a local outbox. TaskBridge Web becomes the durable system for event history, materialized current state, semantic indexing, analytics, and any LLM or MCP features.

This keeps sync logic and source adapters in TaskBridge while explicitly keeping recommendation, inference, ranking, analytics, and LLM behavior out of TaskBridge.

## Decision

Use a versioned Rails-native HTTP push contract with these responsibilities:

- TaskBridge detects observations while syncing provider data.
- TaskBridge stores pending publication rows in a local outbox before attempting delivery.
- TaskBridge pushes batches to TaskBridge Web over authenticated HTTP with per-entry idempotency keys.
- TaskBridge Web durably stores every accepted event, updates current-state projections, manages cross-system mappings, and exposes downstream APIs.
- TaskBridge may also support file or stdout export for development and backfill, but HTTP push is the primary production path.

## Why This Boundary

This boundary matches the current codebase:

- TaskBridge already owns source sync, normalized `sync_items` state, `sync_collections`, and per-service sync status.
- TaskBridge already computes meaningful sync facts such as `items_synced`, `last_attempted`, `last_successful`, `last_failed`, and touched collection IDs.
- TaskBridge does not currently expose an ingestion API and should not grow into an analytics or AI-serving application.

TaskBridge Web is the correct place to own:

- durable history;
- current-state materialization across sources;
- cross-system identity graphs and user-facing provenance views;
- semantic search, embeddings, analytics, and LLM/MCP tools.

## Contract Shape

Every request is versioned and batch-oriented.

- Endpoint: `POST /api/task_bridge/v1/ingestion/batches`
- Authentication: static API key from TaskBridge to TaskBridge Web
- Headers:
  - `Authorization: Bearer <taskbridge_web_ingest_key>`
  - `Content-Type: application/json`
  - `X-TaskBridge-Contract-Version: 1`
  - `X-TaskBridge-Batch-Id: <uuid>`
  - `X-TaskBridge-Sent-At: <iso8601>`
- Body:
  - `contract_version`
  - `batch`
  - `items`
  - `observations`
  - `mappings`
  - `sync_runs`

TaskBridge Web must accept partial batches and return per-entry results keyed by idempotency key.

## Versioning Rules

- `contract_version` is required on every batch and on every record; the payload examples below assume `1`.
- Version `1` consumers must ignore unknown fields.
- New optional fields are backward-compatible within the same version.
- Removing fields, changing semantics, or changing required enum values requires a new major contract version.
- TaskBridge must not silently send `contract_version: 2` payloads to a `v1` endpoint.
- TaskBridge Web should keep at least one prior major contract version available during rollout windows.

## Identity Model

### Source identity

Every item or observation must identify the source record with:

- `service_type`: stable adapter family such as `asana`, `omnifocus`, `github`, `google_tasks`
- `service_instance`: stable identifier for the configured account/workspace/app instance inside TaskBridge
- `external_id`: provider-native item identifier
- `source_url`: canonical provider URL when available
- `source_collection_keys`: provider collection identifiers such as project/list/section IDs
- `source_timestamps`: provider-native created/updated/completed/deleted timestamps when available

`service_instance` must distinguish two configured accounts of the same provider. The minimum shape is:

```json
{
  "service_type": "asana",
  "service_instance": "asana:workspace-12345:default",
  "external_id": "1201234567890"
}
```

TaskBridge owns the `service_instance` format. It must be stable for the life of that configuration and unique within one TaskBridge deployment.

### Cross-system identity

Cross-system identity is represented separately from the source item snapshot.

- `sync_collection_id`: TaskBridge’s internal representation group when one exists
- `membership_role`: optional role within the representation, usually `canonical` or `member`
- `mapping_confidence`: `confirmed`, `inferred`, or `tentative`
- `mapping_source`: how the mapping was established, such as `sync_id_note`, `direct_external_reference`, `title_match`, `manual`
- `provenance`: structured explanation of the evidence TaskBridge used

This keeps source facts separate from TaskBridge’s local matching judgment.

## Minimum Normalized Item Snapshot Schema

An item snapshot is the minimum current-state document TaskBridge can publish for a source item.

Required fields:

- `contract_version`
- `idempotency_key`
- `item_key`
- `entity_type`
- `observed_at`
- `title`
- `status`
- `is_deleted`
- `source`

Recommended minimum optional fields:

- `completed_at`
- `source_created_at`
- `source_updated_at`
- `due_at`
- `started_at`
- `notes_preview`
- `tags`
- `parent`
- `sync_collection`
- `source_metadata`

Schema:

```json
{
  "contract_version": 1,
  "idempotency_key": "tb:v1:item:asana:workspace-12345:default:1201234567890:snapshot:2026-08-14T19:20:31.123456Z",
  "item_key": "asana:workspace-12345:default:1201234567890",
  "entity_type": "task",
  "observed_at": "2026-08-14T19:20:31.123456Z",
  "title": "Buy milk",
  "status": "open",
  "is_deleted": false,
  "completed_at": null,
  "source_created_at": "2026-08-10T12:00:00Z",
  "source_updated_at": "2026-08-14T18:58:02Z",
  "due_at": "2026-08-15T17:00:00Z",
  "started_at": null,
  "notes_preview": "2% and eggs",
  "tags": ["Errands", "Home"],
  "parent": {
    "external_id": null,
    "item_key": null
  },
  "source": {
    "service_type": "asana",
    "service_instance": "asana:workspace-12345:default",
    "external_id": "1201234567890",
    "source_url": "https://app.asana.com/0/12345/1201234567890",
    "source_collection_keys": [
      { "kind": "project", "id": "project-9" },
      { "kind": "section", "id": "section-3" }
    ]
  },
  "sync_collection": {
    "sync_collection_id": 84,
    "membership_role": "member",
    "mapping_confidence": "confirmed",
    "mapping_source": "sync_id_note"
  },
  "source_metadata": {
    "item_type": "task"
  }
}
```

### Common vs source-specific fields

Common normalized fields:

- identity: `item_key`, `entity_type`, `source.*`
- lifecycle: `observed_at`, `status`, `is_deleted`, `completed_at`
- task shape: `title`, `due_at`, `started_at`, `parent`, `tags`
- mapping: `sync_collection.*`
- provenance timestamps: `source_created_at`, `source_updated_at`

Source-specific metadata belongs only in `source_metadata` and must not be required for core ingestion behavior.

Examples:

- Asana section or workspace details
- OmniFocus project/container details
- GitHub issue numbers or repository names

## Minimum Normalized Observation Schema

Observations are append-only facts about what TaskBridge saw or concluded at a point in time. They are not just snapshots; they preserve change history.

Required fields:

- `contract_version`
- `idempotency_key`
- `event_type`
- `observed_at`
- `item_key`
- `source`

Minimum schema:

```json
{
  "contract_version": 1,
  "idempotency_key": "tb:v1:obs:asana:workspace-12345:default:1201234567890:source_changed:2026-08-14T19:20:31.123456Z",
  "event_type": "source_changed",
  "observed_at": "2026-08-14T19:20:31.123456Z",
  "published_at": "2026-08-14T19:20:33.000000Z",
  "item_key": "asana:workspace-12345:default:1201234567890",
  "source": {
    "service_type": "asana",
    "service_instance": "asana:workspace-12345:default",
    "external_id": "1201234567890",
    "source_url": "https://app.asana.com/0/12345/1201234567890"
  },
  "change": {
    "field": "status",
    "from": "open",
    "to": "completed"
  },
  "source_created_at": "2026-08-10T12:00:00Z",
  "source_updated_at": "2026-08-14T19:19:58Z",
  "completed_at": "2026-08-14T19:19:58Z",
  "provenance": {
    "detected_by": "sync_compare",
    "sync_run_id": "sync-run-20260814T192000Z-asana"
  }
}
```

Supported v1 `event_type` values:

- `snapshot_seen`
- `source_changed`
- `mapping_changed`
- `deleted`
- `sync_run_finished`

`item_key` is required but may be `null` for run-scoped event types such as `sync_run_finished`; item-scoped fields are only meaningful when `item_key` is present.

## Idempotency Keys

TaskBridge must create deterministic record-level idempotency keys.

Format:

`tb:v1:<record_kind>:<service_instance>:<external_id_or_scope>:<event_type_or_kind>:<observed_at_or_sequence>`

Rules:

- Prefix all keys with `tb:v1`.
- Keys must be deterministic for the same published fact.
- If TaskBridge retries the same outbox row, it must reuse the same idempotency key.
- Different facts about the same item must use different keys.
- Batch IDs are transport identifiers only and do not replace record-level idempotency keys.

Examples:

- item snapshot:
  - `tb:v1:item:asana:workspace-12345:default:1201234567890:snapshot:2026-08-14T19:20:31.123456Z`
- observation:
  - `tb:v1:obs:asana:workspace-12345:default:1201234567890:source_changed:2026-08-14T19:20:31.123456Z`
- mapping update:
  - `tb:v1:map:sync_collection:84:membership:asana:workspace-12345:default:1201234567890`
- sync run summary:
  - `tb:v1:sync_run:asana:workspace-12345:default:sync-run-20260814T192000Z-asana`

## Timestamps

Required timestamp semantics:

- `observed_at`: when TaskBridge observed or concluded the fact
- `published_at`: when TaskBridge attempted publication for this payload row
- `source_created_at`: provider creation time if known
- `source_updated_at`: provider last modification time if known
- `completed_at`: completion timestamp if the item is complete and the source exposes one

Required on sync-run summaries:

- `started_at`
- `finished_at`
- `last_attempted_at`
- `last_successful_at` or `last_failed_at` as applicable

Rules:

- All timestamps must be ISO 8601 UTC with microseconds when available.
- Unknown source timestamps may be `null`.
- `published_at` is transport metadata and may differ across retries; the idempotency key must not change.

## Deletes and Tombstones

TaskBridge must represent deletions explicitly instead of silently omitting missing items.

Deletion rules:

- If a source clearly marks an item deleted, publish `event_type: deleted`.
- If a source no longer returns an item that TaskBridge previously observed, publish a tombstone observation only when the adapter can distinguish disappearance from temporary listing incompleteness.
- Tombstones must preserve source identity, last known title when available, and `observed_at`.
- After a tombstone, TaskBridge may publish a current-state snapshot with `is_deleted: true`.

Example tombstone observation:

```json
{
  "contract_version": 1,
  "idempotency_key": "tb:v1:obs:omnifocus:default:task-77:deleted:2026-08-14T19:30:00.000000Z",
  "event_type": "deleted",
  "observed_at": "2026-08-14T19:30:00.000000Z",
  "published_at": "2026-08-14T19:30:01.000000Z",
  "item_key": "omnifocus:default:task-77",
  "source": {
    "service_type": "omnifocus",
    "service_instance": "omnifocus:default",
    "external_id": "task-77",
    "source_url": "omnifocus:///task/task-77"
  },
  "last_known": {
    "title": "Buy milk",
    "status": "open"
  },
  "is_deleted": true,
  "provenance": {
    "detected_by": "missing_from_authoritative_fetch",
    "sync_run_id": "sync-run-20260814T192500Z-omnifocus"
  }
}
```

## Mapping Update Schema

Mappings are separate events so TaskBridge Web can track representation changes without diffing snapshots.

```json
{
  "contract_version": 1,
  "idempotency_key": "tb:v1:map:sync_collection:84:membership:github:repo-1:issue-42",
  "mapping_type": "representation_membership",
  "observed_at": "2026-08-14T19:21:00.000000Z",
  "sync_collection": {
    "sync_collection_id": 84,
    "title": "Release checklist"
  },
  "member": {
    "item_key": "github:repo-1:issue-42",
    "service_type": "github",
    "service_instance": "github:repo-1",
    "external_id": "issue-42"
  },
  "membership_role": "member",
  "mapping_confidence": "tentative",
  "mapping_source": "title_match",
  "provenance": {
    "matched_fields": ["title"],
    "notes": "Single-title match during sync"
  }
}
```

## Sync-Run Summary Schema

TaskBridge should publish one sync-run summary per service run so TaskBridge Web can correlate item observations with operational health.

This schema should align with facts already produced by `StructuredLogger` and service `sync_result`.

```json
{
  "contract_version": 1,
  "idempotency_key": "tb:v1:sync_run:asana:workspace-12345:default:sync-run-20260814T192000Z-asana",
  "sync_run_id": "sync-run-20260814T192000Z-asana",
  "service_type": "asana",
  "service_instance": "asana:workspace-12345:default",
  "started_at": "2026-08-14T19:20:00.000000Z",
  "finished_at": "2026-08-14T19:21:05.000000Z",
  "last_attempted_at": "2026-08-14T19:20:00.000000Z",
  "last_successful_at": "2026-08-14T19:21:05.000000Z",
  "last_failed_at": null,
  "status": "success",
  "items_synced": 12,
  "touched_sync_collection_ids": [84, 91],
  "detail": "12 items processed",
  "error": null
}
```

Failure example:

```json
{
  "contract_version": 1,
  "idempotency_key": "tb:v1:sync_run:github:repo-1:sync-run-20260814T193000Z-github",
  "sync_run_id": "sync-run-20260814T193000Z-github",
  "service_type": "github",
  "service_instance": "github:repo-1",
  "started_at": "2026-08-14T19:30:00.000000Z",
  "finished_at": "2026-08-14T19:30:02.000000Z",
  "last_attempted_at": "2026-08-14T19:30:00.000000Z",
  "last_successful_at": null,
  "last_failed_at": "2026-08-14T19:30:02.000000Z",
  "status": "failed",
  "items_synced": 0,
  "touched_sync_collection_ids": [],
  "detail": "ProviderError: 401 unauthorized",
  "error": {
    "class": "ProviderError",
    "message": "401 unauthorized",
    "retryable": false
  }
}
```

## Batch Request Example

```json
{
  "contract_version": 1,
  "batch": {
    "batch_id": "2fd13f74-02ec-4dfd-b21c-3837a66a3768",
    "sent_at": "2026-08-14T19:21:10.000000Z",
    "publisher": "task_bridge",
    "publisher_instance": "task-bridge-macbook-pro"
  },
  "items": [],
  "observations": [],
  "mappings": [],
  "sync_runs": []
}
```

## TaskBridge Web Endpoint Expectations

The first compatible ingestion surface required under #214 is:

- `POST /api/task_bridge/v1/ingestion/batches`

Minimum behavior:

- authenticate by API key;
- validate `contract_version`;
- process `items`, `observations`, `mappings`, and `sync_runs` independently;
- enforce idempotency per record using `idempotency_key`;
- persist accepted records durably before responding success;
- support partial success;
- return retry guidance per failed row.

Recommended response:

```json
{
  "batch_id": "2fd13f74-02ec-4dfd-b21c-3837a66a3768",
  "contract_version": 1,
  "accepted": 1,
  "rejected": 1,
  "results": [
    {
      "idempotency_key": "tb:v1:item:asana:workspace-12345:default:1201234567890:snapshot:2026-08-14T19:20:31.123456Z",
      "status": "accepted"
    },
    {
      "idempotency_key": "tb:v1:obs:omnifocus:default:task-77:deleted:2026-08-14T19:30:00.000000Z",
      "status": "rejected",
      "retryable": false,
      "error_code": "validation_error",
      "message": "source.service_instance is required"
    }
  ]
}
```

HTTP status guidance:

- `200 OK`: batch parsed; inspect per-row statuses
- `401 Unauthorized`: invalid API key; terminal until secrets are fixed
- `413 Payload Too Large`: retryable after smaller batches
- `422 Unprocessable Entity`: contract or row validation failure; usually terminal for listed rows
- `429 Too Many Requests`: retryable with backoff
- `5xx`: retryable

## Failure Semantics

Publication must be at-least-once with idempotent ingestion.

TaskBridge rules:

- Store every pending row in a local outbox before publish.
- Mark rows delivered only after TaskBridge Web accepts them.
- Retry retryable failures with exponential backoff and jitter.
- Keep terminal failures in the outbox with failure status for operator review.
- Allow manual or scripted replay by batch range, time range, service, or sync run.

TaskBridge Web rules:

- Evaluate each row independently.
- Return `retryable: true` only for transient errors.
- Never require clients to guess whether a row was persisted.
- Treat duplicate `idempotency_key` submissions as success if the original payload was already accepted.

## Security and Privacy Constraints

Allowed to leave TaskBridge:

- normalized task title
- normalized status and timestamps
- provider URLs
- provider IDs
- provider collection IDs and names when needed for provenance
- non-secret notes preview or normalized notes only if explicitly approved by configuration
- mapping evidence and sync-run summaries

Must not leave TaskBridge by default:

- API tokens, OAuth credentials, cookies, session data
- private sync notes used only for local bridging internals unless explicitly designated safe
- provider payloads that include secrets or unrelated personal data
- full raw source payloads

Rules:

- Treat all notes/body content as sensitive by default.
- `notes_preview` should be omitted or redacted unless the source is explicitly allowlisted for note export.
- TaskBridge should prefer normalized excerpts over raw provider payloads.
- TaskBridge Web must not require raw source blobs for v1 ingestion.

## Migration and Backfill Implications

- Add a local outbox table in TaskBridge for durable pending publications.
- Existing `sync_items`, `sync_collections`, and `sync_service_states` are enough to seed an initial backfill.
- Backfill should emit:
  - one current-state item snapshot per known source item;
  - mapping rows for known `sync_collection` memberships;
  - sync-run summaries only where reliable historical timestamps exist;
  - deletion tombstones only where deletion can be stated confidently.
- Backfill may use the same HTTP contract or file/stdout export piped into TaskBridge Web import jobs.
- Backfill records must still carry deterministic idempotency keys so reruns are safe.

## Rejected Alternatives

### Poll TaskBridge from TaskBridge Web

Rejected because:

- it requires TaskBridge to expose and operate a query API;
- it makes TaskBridge responsible for another durable serving surface;
- it weakens retry control because the producer no longer owns durable publication state.

### Send only sync-run summaries

Rejected because:

- summaries do not represent item history, deletions, or cross-system mappings;
- TaskBridge Web would have to reconstruct facts from incomplete aggregates.

### Send only current-state snapshots

Rejected because:

- snapshots alone do not preserve meaningful changes or explicit deletions;
- TaskBridge Web would need to compute history heuristically.

### Publish raw provider payloads

Rejected because:

- it leaks provider-specific complexity into TaskBridge Web;
- it expands privacy risk;
- it couples ingestion to every source adapter’s raw shape.

### Put embeddings, recommendations, or LLM enrichment in TaskBridge

Rejected because:

- it violates the intended app boundary;
- it makes sync execution depend on analytics/AI concerns;
- it would force provider adapters to own unstable product logic.

## Implementation Notes for Follow-up Issues

The first implementation issues under #214 can proceed with these assumptions:

- TaskBridge needs an outbox model and batch publisher.
- TaskBridge Web needs the `v1` ingestion endpoint and idempotent persistence.
- Both sides should treat `sync_collection` membership and deletion as first-class records, not inferred side effects.
- LLM or recommendation behavior remains entirely outside TaskBridge.
