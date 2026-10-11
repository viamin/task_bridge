# Backfilling the TaskBridge Web baseline

TaskBridge Web starts from TaskBridge's current state, not from a replayed
history. This document explains how to seed the outbox with baseline rows for
existing synchronized data before enabling publication (issue #222, parent
#214, per RDR
[215](rdr-215-taskbridge-observation-publication-contract.md) — see
"Migration and Backfill Implications").

## What the backfill writes

The backfill is **local-only**: it reads `sync_items`, `sync_collections`,
and their stored notes/metadata, and writes rows into the local
`outbox_entries` table. It never contacts OmniFocus, Asana, GitHub, Google
Tasks, or any other external source system, and it never mutates provider
data.

Per existing `sync_items` row:

- One current-state **`item` snapshot** row (`record_kind: item`) built from
  the normalized snapshot, so TaskBridge Web can materialize current state.
- No `snapshot_seen` observation rows. Baseline rows are not historical
  change events; each carries `provenance.detected_by: "backfill"` plus a
  `backfilled_at` timestamp (which reuses the row's deterministic
  `observed_at` so reruns reproduce byte-identical payloads).

Per existing `SyncCollection` membership:

- A **`mapping`** row — but only for mappings TaskBridge holds at
  `high`/`confirmed` or `medium`/`inferred` confidence
  (`source_sync_id`/`created_by_sync` and `title_fallback` evidence).
  Low-confidence (`manual_backfill`) memberships map to the contract's
  `tentative` and are **withheld** from publication, per the product
  decision that resolved RDR 215's open question. They remain identifiable
  for manual cleanup in the dry-run summary (counts by confidence plus a
  member-by-member list).

The backfill writes **no `sync_run` rows**: `sync_service_states` holds only
the latest attempt per service with no reliable per-run start/end
timestamps, which RDR 215 requires for backfilled sync-run summaries. Live
sync runs publish them going forward (#219–#221).

Before emitting, `run!` also executes the idempotent source-provenance
backfill (`task_bridge:backfill_sync_provenance`, #218), which fills
identity fields (`source_service_name`, `source_service_instance`,
`source_external_id`, `source_url`, `first_observed_at`/`last_observed_at`,
STI type, parsed sync-id notes) and `SyncCollection` mapping metadata — so
rows can be enqueued even for legacy rows that predate those columns.

## Running it

```bash
# 1. Preview first: counts by service and confidence, skipped/incomplete
#    records, and the withheld low-confidence membership list. Writes
#    nothing, sends nothing.
bundle exec rake task_bridge:outbox:backfill_baseline_dry_run

# 2. Backfill the outbox. Safe to run repeatedly (see below).
bundle exec rake task_bridge:outbox:backfill_baseline

# 3. Inspect what would be sent (renders NDJSON batches to stdout).
bundle exec rake task_bridge:outbox:publish_dry_run

# 4. Enable and publish (task_bridge.web.enabled in settings).
bundle exec rake task_bridge:outbox:publish
```

Run the backfill **before** enabling TaskBridge Web publication
(`task_bridge.web.enabled`), so the first real sync after enablement
delivers the baseline and only later diffs arrive as change history.

## Idempotency

The backfill can be run multiple times safely:

- Every row's idempotency key embeds a deterministic `observed_at` derived
  from stored data (`sync_items.last_observed_at`, falling back to record
  timestamps; `sync_collections.mapping_last_observed_at`), so a rerun with
  unchanged data reproduces the same keys, and the outbox's unique index
  de-duplicates them.
- Rows recreated after delivered rows were pruned reproduce the identical
  canonical payload, which TaskBridge Web treats as a replay rather than a
  conflict.
- An item that legitimately changed between two backfill runs gets a new
  row for the newer observation — that is a new fact, not a duplicate.
- The dry-run task performs no writes at all (it does not even run the
  source-provenance backfill), so it is safe to point at production data.

## Identity note

Rows for services without a configured instance suffix (OmniFocus, GitHub,
Google Tasks, ...) use the permanent `:default` service-instance token
(e.g. `omnifocus:default`), matching the RDR 215 identity example. The
token is embedded in idempotency keys and can never change; the live
pipeline resolves the same default through `Outbox::SourceIdentity` so
backfilled and live rows share identities.

## Reviewing low-confidence mappings

Withheld memberships appear only in the dry-run summary, for example:

```
Mappings: 0 planned, 2 withheld low-confidence, 0 skipped incomplete
Mappings by confidence: tentative: 2
Withheld low-confidence memberships:
  sync_collection 7 "Maybe linked": asana_work:asana-low (manual_backfill)
  sync_collection 7 "Maybe linked": omnifocus:of-low (manual_backfill)
```

To promote one, link the representations with real evidence (sync-id notes
or a fresh sync that matches them) so the collection's mapping confidence
rises; the next backfill or live sync then publishes the membership.
