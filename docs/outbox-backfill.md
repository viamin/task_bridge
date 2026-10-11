# Outbox backfill: baseline snapshots and mappings for TaskBridge Web

- Status: Delivered (#222)
- Parent epic: #214
- Depends on: #216 (normalized snapshots), #217 (outbox), #218 (provenance columns + `SyncBackfill::SourceProvenance`)
- Contract of record: RDR #215 (`docs/rdr-215-taskbridge-observation-publication-contract.md`)

## Why

Existing `sync_items` and `sync_collections` rows represent real synchronized
work that predates the observation pipeline (#219-#221). The backfill
publishes them as **baseline current state** — one `item` snapshot per sync
item and one `mapping` row per `SyncCollection` membership — so TaskBridge
Web starts from known state and only later diffs become change history.

## What it writes

| Outbox row | Source | Notes |
| --- | --- | --- |
| `item` snapshot | each `sync_items` row with an external ID | Baseline current state; no `snapshot_seen` observation rows are emitted from the backfill. |
| `mapping` | each `SyncCollection` member with an external ID | Only for memberships whose mapping confidence publishes as `confirmed` or `inferred`. |
| `sync_run` | none | `sync_service_states` has no reliable per-run start/end timestamps, so sync-run summaries wait for live runs (RDR #215). |
| tombstones | none | The backfill cannot state any deletion confidently. |

Baseline rows are marked, never passed off as historical change events:
every payload carries `provenance.detected_by: "backfill"` plus the run's
`backfilled_at` timestamp, and `observed_at` reflects the record's own last
observation time — not the backfill wall clock.

The apply run also stores each item's `last_snapshot` diff baseline (when
blank), so the first live refresh after the backfill publishes only genuine
changes instead of re-announcing the baseline as a fresh discovery.

## Resolved decisions

- **Low-confidence mappings are withheld** (resolves RDR #215's open
  question): internal `high` publishes as `confirmed`, `medium` as
  `inferred`, and `low` (plus still-unknown provenance) is never enqueued.
  Withheld memberships stay identifiable through the dry-run summary counts
  by confidence, for later manual cleanup or Web-side review. Live sync
  (#219) continues to publish every membership it (re-)establishes; only
  the backfill withholds.
- **One `item` snapshot per item**, no `snapshot_seen` observation rows from
  the backfill — extra payload fields like `provenance.detected_by` are safe
  because v1 consumers ignore unknown fields.
- **`service_instance` default token**: services configured without an
  instance suffix (OmniFocus, Google Tasks, Reminders, …) publish as
  `<service_type>:default` (e.g. `omnifocus:default`). The token is
  permanent — it is embedded in idempotency keys — and the live pipeline
  resolves the same default (`Outbox::SourceIdentity::DEFAULT_INSTANCE`) so
  backfilled and live rows share identities.
- **No `sync_run` rows from backfill** (see table above).

## Running the backfill

Run the backfill **before** enabling publication to TaskBridge Web
(`task_bridge.web.enabled` stays `false` until the outbox is seeded):

```bash
# 1. Preview: counts by service and confidence, skipped/incomplete records.
#    Writes nothing (no provenance backfill, no outbox rows, no baselines).
bin/rails task_bridge:outbox:backfill_dry_run

# 2. Apply: idempotent; also runs the #218 provenance backfill first.
bin/rails task_bridge:outbox:backfill

# 3. Publish the seeded outbox once TaskBridge Web is configured, then let
#    the hourly sync runs publish incrementally (or run the task manually).
bin/rails task_bridge:outbox:publish
```

Sample dry-run output:

```
Outbox backfill dry run (nothing was written): would enqueue 6 item snapshots (1 skipped) and 4 mappings (2 low-confidence memberships would be withheld, 0 skipped)
Items by service: asana=2, github=1, google_tasks=1, omnifocus=2
Mappings by confidence: confirmed=2, inferred=2, tentative=2
```

## Idempotency and safety

- **Rerunnable**: every row's idempotency key derives from the record's own
  stored observation timestamps (`sync_items.last_observed_at`,
  `sync_collections.mapping_last_observed_at`), not the run time, so reruns
  find their rows already present and leave them untouched. Rerunning after
  live syncs have advanced those timestamps simply publishes the newer
  current state under a new key.
- **Local writes only**: the backfill reads persisted state and never
  contacts a provider, so it cannot mutate an external source system.
- **Loud failures**: unlike the live emitters it does not isolate and drop
  failed writes — a failed backfill aborts and is simply rerun.
- **Publication stays opt-in**: backfilling only fills the local outbox; it
  never enables or performs publication (RDR #215 rollout boundary).

## Where to look in the code

| Piece | Location |
| --- | --- |
| Orchestrator (apply/preview) | `app/services/outbox/backfill.rb` |
| Provenance backfill (runs first on apply) | `app/services/sync_backfill/source_provenance.rb` |
| Confidence vocabulary for the contract | `Outbox::MappingEmitter::CONFIDENCE` |
| Service instance default token | `Outbox::SourceIdentity::DEFAULT_INSTANCE` |
| Rake tasks | `lib/tasks/outbox.rake` |
