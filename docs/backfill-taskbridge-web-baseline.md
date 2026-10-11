# TaskBridge Web Baseline Backfill Runbook

Issue #222 under #214. This runbook explains how to seed TaskBridge Web with
the existing synchronized data before publication is enabled, so TaskBridge
Web starts from the known current state and only treats later diffs as change
history. The contract this implements is
[docs/rdr-215-taskbridge-observation-publication-contract.md](rdr-215-taskbridge-observation-publication-contract.md).

## What the backfill writes

The backfill is read-only toward every external source system; it only reads
existing local rows (`sync_items`, `sync_collections`) and writes the local
outbox. For each existing record it emits:

- **One `item` snapshot per `sync_items` row** — the current-state document
  from the normalized snapshot, marked as a baseline observation rather than
  a historical change event: `provenance.detected_by: "backfill"`, plus
  `provenance.backfilled_at` and `provenance.first_observed_at`. No
  `snapshot_seen` observation rows are emitted from the backfill; live sync
  runs keep publishing observations going forward (#219).
- **One `mapping` row per `SyncCollection` membership** — published through
  `Outbox::MappingEmitter`, so membership rows use the same payload and keys
  as live sync-time emission.
- **No `sync_run` rows** — `sync_service_states` has no reliable per-run
  `started_at`/`finished_at`, and the RDR only backfills sync-run summaries
  where reliable historical timestamps exist. Normal sync runs publish them
  going forward.

Before the outbox rows are built, the backfill (idempotently) runs
`SyncBackfill::SourceProvenance` (#216-#218) so every item carries explicit
identity/provenance (STI type, `external_id`, `url`, `last_modified`, parsed
notes, inferred service instance names) and every collection carries mapping
provenance.

## Low-confidence mapping policy (decision point)

Internal `SyncCollection` mapping confidence translates to the contract
vocabulary as:

| Internal confidence | Internal method (examples) | Contract `mapping_confidence` | Backfill publishes? |
| --- | --- | --- | --- |
| `high` | `source_sync_id`, `created_by_sync` | `confirmed` | yes |
| `medium` | `title_fallback` (title-derived) | `inferred` | yes |
| `low` | `manual_backfill` / no evidence | `tentative` | **no — withheld** |

This resolves the RDR #215 open question toward the RDR's stated default
(publish only `confirmed` and `inferred` mappings). It remains an explicit
product decision point: if the product owner later decides low-confidence
memberships should reach TaskBridge Web for review there, change
`Outbox::MappingEmitter.publishable_confidence?` (and the withholding in
`SyncBackfill::Baseline`) in one place. Until then, withheld memberships are
identifiable only through the dry-run summary below — for manual cleanup or
a later re-run after the underlying mappings are upgraded by live sync.

Item snapshots for members of withheld collections are still published; they
simply omit the optional `sync_collection` membership block.

## How to run it

```bash
# 1. Preview what would be enqueued (writes nothing):
bundle exec rake task_bridge:outbox:backfill_baseline_dry_run

# 2. Run the real backfill (idempotent — safe to run repeatedly):
bundle exec rake task_bridge:outbox:backfill_baseline

# 3. Preview the exact HTTP batches publication would send (optional):
bundle exec rake task_bridge:outbox:publish_dry_run
```

Run the backfill **before** enabling publication (`task_bridge.web.enabled`
in settings). Publication stays disabled by default and is unchanged by the
backfill; enabling it afterward delivers the baseline rows plus any live
rows enqueued since.

The dry-run task prints counts by service and confidence, skipped/incomplete
records, and the list of withheld low-confidence collections, for example:

```
Baseline backfill dry run: would enqueue 412 item snapshots (3 incomplete) and 356 mapping rows (12 would be withheld low confidence, 0 incomplete); nothing was written
Item snapshots by service: asana=180, github=96, google_tasks=78, omnifocus=58
Mapping rows by confidence: confirmed=322, inferred=34
Withheld low confidence: sync_collection 84 (1 members, method: manual_backfill) "Mystery pair"
```

Dry-run numbers are computed with the same provenance inference the real run
persists, but nothing is written; item identities that depend on the
provenance backfill (for example an instanced service name recovered from
peer notes) are finalized during the real run.

## Idempotency and safety

- Reruns skip any source identity that already has its baseline `item` or
  `mapping` row, and enqueued rows use deterministic idempotency keys built
  from stable per-record timestamps (`last_observed_at`,
  `mapping_last_observed_at`). Running the backfill multiple times never
  duplicates facts at TaskBridge Web.
- If an outbox row was already delivered and pruned by retention, a rerun
  re-enqueues the same key with the same payload; TaskBridge Web replays it
  as a no-op.
- Live sync rows and backfilled rows share identity: services without a
  configured instance suffix publish under the permanent default
  `<service_type>:default` (for example `omnifocus:default`), and instanced
  services keep their segment (`asana:work`). The token is embedded in
  idempotency keys and can never change.
- The backfill never mutates external source systems and never calls
  provider APIs; it only builds payloads from local rows.
