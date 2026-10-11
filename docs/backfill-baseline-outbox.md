# Backfilling the TaskBridge Web Baseline (#222)

TaskBridge Web needs a known starting state before it can treat later
observations as change history (RDR #215, "Migration and Backfill
Implications"). The baseline backfill seeds the local outbox from sync data
that already exists — `sync_items`, `sync_collections`, and their recorded
provenance — without contacting any provider.

Parent epic: #214. Contract: `docs/rdr-215-taskbridge-observation-publication-contract.md`.

## What the backfill writes

- **One `item` snapshot row per known `sync_items` row** — the item's
  current state in the normalized snapshot schema, marked as baseline in the
  payload (`provenance.detected_by: "backfill"` plus a `backfilled_at`
  timestamp). Extra payload fields are safe: version 1 consumers must ignore
  unknown fields.
- **One `mapping` row per `sync_collection` membership** the Web is allowed
  to see, carrying the collection's mapping method/confidence and the same
  baseline provenance markers.
- **Nothing else.** No `snapshot_seen` or `source_changed` observations, no
  deletion tombstones, and no `sync_run` summaries: `sync_service_states`
  has no reliable per-run timestamps, and fabricating history from current
  state would misrepresent when things changed (clarified under #222).

Before enqueuing anything, the backfill runs the prerequisite provenance
pass (`rake task_bridge:backfill_sync_provenance` logic) so legacy rows get
their source identity (`source_service_*`, `first/last_observed_at`) and
collections get mapping metadata (`mapping_method`,
`mapping_confidence`, …). That pass is idempotent and only fills local
columns.

## Confidence handling (resolves RDR #215's open question)

Internal mapping confidence translates to the contract enum as:

| TaskBridge (`SyncCollection.mapping_confidence`) | Contract (`mapping_confidence`) | Backfill behavior |
|---|---|---|
| `high` | `confirmed` | enqueued |
| `medium` (title-derived) | `inferred` | enqueued |
| `low` / unknown | `tentative` | **withheld** |

Low-confidence memberships are not published by the backfill. They stay
identifiable for manual cleanup through:

- the dry-run summary's counts by confidence (see below), and
- `SyncCollection.where(mapping_confidence: "low")` locally.

Once an operator upgrades a collection's provenance (for example, after
adding sync-id notes during a cleanup pass), the next backfill run publishes
the upgraded memberships.

## How to run it

Run the backfill **before** enabling publication to TaskBridge Web
(`task_bridge.web.enabled` stays `false` until the baseline is seeded):

```bash
# 1. Preview: counts by service and confidence, plus skipped/incomplete
#    records. Writes nothing.
bundle exec rake task_bridge:outbox:backfill_baseline_dry_run

# 2. Seed the outbox (prints the same summary; also prints any rows whose
#    write was isolated and dropped for retry).
bundle exec rake task_bridge:outbox:backfill_baseline

# 3. Optionally inspect the exact batches that would be sent (NDJSON on
#    stdout, nothing is delivered):
bundle exec rake task_bridge:outbox:publish_dry_run

# 4. Enable task_bridge.web (config/settings.yml or TASK_BRIDGE_WEB_*
#    environment variables); pending rows — baseline and live — publish on
#    the next task_bridge:outbox:publish run.
```

Example dry-run output:

```
Baseline backfill (dry run) at 2026-10-11T09:00:00.000000Z
Items: 812 would enqueue (github: 210, google_tasks: 314, omnifocus: 271, asana: 17); 0 already backfilled; 2 skipped incomplete (omnifocus: 2)
Mappings: 640 of 655 memberships would enqueue across 327 collections (confirmed: 512, inferred: 128); 15 withheld (low: 15); 0 skipped incomplete
```

## Idempotency and reruns

- Item rows are seeded **once per source identity** (`service_type`,
  `service_instance`, `external_id`): identities that already have an `item`
  row are skipped and reported as `already backfilled`, so live syncs
  re-observing items between runs never trigger a second baseline wave.
- Mapping rows use deterministic idempotency keys over the collection's
  stable mapping timestamps; `OutboxEntry.enqueue` returns the stored row
  untouched when the key exists, so reruns never duplicate rows or rewrite
  already-enqueued payloads.
- A row whose write keeps failing (for example, a transient SQLite lock) is
  reported on stderr and simply retried by the next run.

## Identity notes

`service_instance` for services configured without an instance suffix
(OmniFocus, Google Tasks, single-account GitHub, …) is
`<service_type>:default` — for example `omnifocus:default` — matching RDR
#215's example shape. This default is permanent (it is embedded in
idempotency keys) and is shared by the live emitters through
`Outbox::SourceIdentity`, so backfilled and live rows for the same item
carry identical identities. Instanced services keep
`<service_type>:<instance>` (for example `asana:work`).
