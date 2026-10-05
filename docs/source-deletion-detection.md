# Source Deletion, Archival, and Disappearance Detection

- Issue: #220
- Parent: #214
- Depends on: #216, #217, #218 (normalized snapshots, sync item provenance,
  local observation outbox)
- Contract: RDR #215 (`docs/rdr-215-taskbridge-observation-publication-contract.md`),
  "Deletes and Tombstones"

TaskBridge Web needs to distinguish inactive or stale work from source data
that actually disappeared. Absence from one sync result is **not** always
deletion: some services return filtered or incremental lists, sources have
outages, and syncs can be partial. This document defines how TaskBridge
represents disappearances explicitly and conservatively, per source.

## Disappearance states

Tombstone observations carry a `disappearance_state` refining the coarse
`event_type: deleted` bucket (defined in `Disappearance::States`):

| State | Meaning |
|---|---|
| `source_deleted` | The source states the item was destroyed (API 404 on direct lookup, or absence from a complete full-list fetch). |
| `source_archived` | The source moved the item out of the active universe (e.g. Asana's `archived` flag). Reversible, so `is_deleted` is `false`. |
| `no_longer_visible` | The item left the range of what the source returns to TaskBridge (moved list/project, cleared), but was not verifiably destroyed. |
| `no_longer_matches_query` | The item verifiably still exists in the source but no longer matches the query TaskBridge uses (e.g. an OmniFocus task that lost its sync tag). |
| `possibly_missing_after_partial_sync` | Defined for consumers classifying runs with partial fetches. **Never emitted by TaskBridge**: absence from a partial fetch proves nothing, so TaskBridge records nothing rather than a low-confidence guess. |

`is_deleted` is `true` only for `source_deleted`; every other state keeps it
`false` so TaskBridge Web never marks a live item deleted.

## How detection runs

`Disappearance::Detector` is invoked by each adapter at the end of its
canonical item fetch via `Base::Service#record_source_disappearances!`. A
tombstone is enqueued into the outbox (`OutboxEntry`, record kind
`observation`, `event_type: deleted`) only when **all** of the following
hold:

1. The adapter's `deletion_detection_strategy` is enabled (see matrix below).
2. The fetch was complete — `only_modified_dates` fetches never detect.
3. The fetch succeeded (adapters raise on failed reads, so detection is
   never reached after an outage).
4. The service is authorized (an `authorized == false` service suppresses
   detection).
5. The scope the fetch covers was fully readable
   (`deletion_detection_scope_available?` — e.g. the Google Keep note and
   every configured Reminders list must have been found).
6. The candidate item passes `disappearance_candidate?` (e.g. Asana tasks
   completed more than a week ago are expected to be absent).
7. For `filtered_with_verification` strategies, `verify_missing_item`
   returned a conclusive `Disappearance::Finding`. Inconclusive lookups
   (HTTP 5xx, auth failure, AppleScript/web unavailability) emit nothing.

Source outage, auth failure, partial sync, and filtered incremental sync
therefore never produce tombstone observations.

## Idempotency and local state

- Tombstones are enqueued through the outbox with deterministic RDR #215
  idempotency keys; local `sync_items` rows are **never deleted**. TaskBridge
  Web owns the follow-up, and keeping the rows preserves last-known state and
  mapping history.
- After emitting, the detector records a marker in
  `sync_items.source_metadata["disappearance"]`
  (`{"state", "observed_at", "sync_run_id"}`). Re-runs that would produce
  the same state are suppressed; a **state change** (e.g.
  `no_longer_visible` escalating to `source_deleted` after verification)
  emits a new observation with a new idempotency key.
- Observing an item again clears the marker (`capture_source_identity`), so
  a later disappearance is observable as a new fact.
- Tombstone payloads preserve source identity, `last_known` title/status and
  observation timestamps, and `provenance`
  (`detected_by`, `confidence`, `detection_strategy`, `sync_run_id`) per
  RDR #215.
- Sync run IDs follow the RDR #215 scope format
  (`sync-run-<timestamp>-<service>`, e.g. `sync-run-20260814T192000Z-asana`),
  derived per service per run by the detector.

## Per-adapter strategies

| Adapter | Mode | State / confidence | Verification |
|---|---|---|---|
| Google Keep | `full_list_absence` | `source_deleted` / high | Scope guard: note must have been read |
| Reminders | `full_list_absence` | `no_longer_visible` / medium | Scope guard: every mapped list must exist |
| OmniFocus | `filtered_with_verification` | by lookup / high | Direct task lookup by ID |
| Asana | `filtered_with_verification` | by lookup / high–medium | Direct task GET by gid |
| GitHub | disabled | — | Not possible with current API use |
| Google Tasks | disabled | — | Not yet (see below) |
| Instapaper | disabled | — | Not possible with current API use |
| Reclaim | disabled | — | Not possible with current API use |

### Google Keep — full-list absence, `source_deleted`, high confidence

The configured note's list items are the complete universe TaskBridge tracks.
A previously observed embedded stable ID that is gone after a successful
note read was deleted in Keep. Guards:

- The note itself must have been found (a renamed, deleted, or not-yet-rebuilt
  note says nothing about its items — the whole run is suppressed).
- Only items with an embedded stable ID are candidates; foreign items get a
  fresh UUID per fetch and would produce garbage tombstones.
- `only_modified_dates` fetches (the `to_primary` path) skip detection.

### Reminders — full-list absence, `no_longer_visible`, medium confidence

`items_to_sync` enumerates the complete configured lists (completed reminders
included). A previously observed reminder absent from all of them left
TaskBridge's view, but deleted, "cleared completed", and moved-to-another-list
are indistinguishable through AppleScript, so the weaker state applies.
Guards: every mapped list must exist (a renamed list would otherwise look
like mass deletion), and an AppleScript failure while enumerating lists for
the scope check suppresses the whole run rather than crashing it.

### OmniFocus — filtered with verification, high confidence

The canonical fetch (configured sync tags + inbox) is TaskBridge's whole
OmniFocus universe, but a task can also leave it by losing a tag. Detection
only runs for the canonical scope (`canonical_item_scope?`); per-service tag
queries (e.g. `existing_items`, primary-side fetches with
`tags: [service_name]`) cover narrower scopes and are ignored. Every
candidate is verified by direct ID lookup (`task_lookup_status`):

- Task found → `no_longer_matches_query` (it exists; it left the query).
- Stale reference (-1728 "Can't get reference") → `source_deleted`.
- Any other AppleScript/web lookup failure (app not running, invalid
  connection) → **no observation** — lookup unavailability is handled
  separately from task nonexistence.

Note: with OmniFocus as the primary service in the current sync flow, the
canonical universe fetch does not occur during a standard run (items are
fetched per secondary-service tag), so OmniFocus detection activates when a
canonical fetch runs (e.g. future orchestration or when OmniFocus is a
secondary). The mechanism and its tests are in place.

Also note a task observed only through a per-service tag query and never
through the canonical query will verify as `found` and emit
`no_longer_matches_query` once; the statement is accurate (it is outside
TaskBridge's canonical view) and the marker prevents repetition.

### Asana — filtered with verification, high–medium confidence

The project task list query filters by a one-week completion window, active
projects only, and excludes archived tasks, so absence alone proves nothing.
Candidates (open tasks only — completed tasks are expected to age out of the
window and are skipped without a lookup) are verified by a direct task GET:

- 404/410 → `source_deleted` (high).
- `archived: true` → `source_archived` (high).
- Task exists, completed → no observation (expected absence, not
  disappearance).
- Task exists, open → `no_longer_visible` (medium) — moved to a project
  TaskBridge does not track, or otherwise outside the project lists.
- Any other response (5xx, auth) or unparseable body → no observation.

### GitHub — disabled

Issue list queries are filtered by labels and an updated-since window, and
the assigned-issues endpoint is known-incomplete (see the comment on
`Github::Service#list_assigned`). GitHub offers no tombstone or per-issue
deletion event to verify against, and direct lookup could not distinguish
deletion from losing a label or assignment. Absence never becomes a
tombstone.

### Google Tasks — disabled (documented capability)

The API can prove deletion: tasks return `deleted`/`hidden` flags for ~30
days on a `show_deleted` read. TaskBridge's list read is windowed by
`updated_min`/`completed_min` and does not read those flags yet
(see `docs/source-capability-matrix.md`), so detection stays disabled until
the flags are read.

### Instapaper — disabled

Folder reads are limit-windowed (50 unread, 25 recently archived), so a
bookmark can age out of either window without being deleted. The Full API
exposes no single-bookmark fetch to verify by ID. Archiving itself is a
visible folder change, not an absence, and is reported by the normal
snapshot path.

### Reclaim — disabled

The task list query is status-filtered (`COMPLETE,NEW,SCHEDULED,
IN_PROGRESS`) and deleted tasks vanish from it silently; the API provides no
tombstones or events to verify by. Absence never becomes a tombstone.

## Outbox payload shape

Every tombstone is a RDR #215 observation with `event_type: deleted`:

```json
{
  "contract_version": 1,
  "event_type": "deleted",
  "observed_at": "2026-10-05T19:30:00.000000Z",
  "item_key": "google_keep:My Tasks:11111111-2222-3333-4444-555555555555",
  "source": {
    "service_type": "google_keep",
    "service_instance": "GoogleKeep",
    "external_id": "11111111-2222-3333-4444-555555555555"
  },
  "last_known": {
    "title": "Buy milk",
    "status": "open",
    "last_observed_at": "2026-10-04T18:00:00.000000Z"
  },
  "is_deleted": true,
  "disappearance_state": "source_deleted",
  "provenance": {
    "detected_by": "missing_from_full_list",
    "confidence": "high",
    "detection_strategy": "full_list_absence",
    "sync_run_id": "sync-run-20261005T193000Z-google_keep"
  }
}
```
