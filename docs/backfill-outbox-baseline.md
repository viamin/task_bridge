# Outbox Baseline Backfill Runbook

- Issue: #222
- Parent: #214
- Contract: [RDR 215](rdr-215-taskbridge-observation-publication-contract.md)

## Purpose

Existing `sync_items` and `sync_collections` represent real synchronized
work. Before TaskBridge Web publication is enabled for a deployment, the
outbox backfill seeds it with a **baseline** of that work: one current-state
`item` snapshot per known source item and `mapping` rows for existing
`SyncCollection` memberships. TaskBridge Web then starts from the known
current state and only later observations read as change history.

The backfill is deliberately not a history reconstruction:

- Item rows are marked as baseline in the payload (`provenance.detected_by:
  "backfill"` plus a `backfilled_at` timestamp).
- No `snapshot_seen` observations, `deleted` tombstones, or `sync_run`
  summaries are invented — `sync_service_states` has no reliable per-run
  start/end timestamps, and history before the first enabled publication
  cannot be stated confidently.
- It reads only local tables; it never contacts or mutates an external
  source system.

## When to run

Run once, after the observation pipeline's schema is present and **before**
enabling `task_bridge.web.enabled`. If publication is already enabled, the
backfill is still safe — live rows and backfilled rows share the same
identity vocabulary — but the intended rollout is backfill first.

## How to run

```bash
# 1. Preview: counts by service and confidence, nothing written.
bundle exec rake task_bridge:outbox:backfill_dry_run

# 2. Backfill. Completes the source provenance backfill (#216-#218) first,
#    then enqueues baseline rows into the outbox.
bundle exec rake task_bridge:outbox:backfill

# 3. Publish the outbox (or wait for the scheduled sync to publish).
bundle exec rake task_bridge:outbox:publish

# 4. Enable publication in config/settings.yml (task_bridge.web.enabled)
#    or via TASK_BRIDGE_WEB_ENABLED.
```

Example dry-run output:

```
Outbox backfill dry run: would enqueue 412 item snapshots and 190 mapping rows (nothing was written)
  item snapshots by service: asana=140, github=52, google_tasks=30, omnifocus=190
  mapping memberships by confidence: confirmed=120, inferred=70, tentative=13 (13 withheld from publication)
  skipped: 2 items and 1 memberships missing an external id
```

## Low-confidence mappings

Mapping confidence translates to the contract vocabulary as
`high` → `confirmed`, `medium` → `inferred`, `low` → `tentative`.
The backfill withholds `tentative` memberships from publication (the
resolution of RDR 215's open question); they stay identifiable through the
dry-run summary's counts by confidence and remain in `sync_collections`
for later cleanup.

This is an explicit, isolated decision point rather than a fixed product
stance: whether title-derived (`medium`/`inferred`) memberships belong in
the backfill is still open for the product owner to confirm. The policy
lives in one place — `Outbox::Backfill::PUBLISHED_CONFIDENCES` — so
changing which confidences publish is a one-line change plus a rerun; no
other migration is needed because reruns are idempotent and withheld rows
were never written.

To publish a withheld membership later, raise its confidence through
normal operation — the live pipeline re-emits mapping rows whenever sync
establishes stronger evidence (for example a sync-id match after the
items' notes are updated) — or correct the membership manually and rerun
the backfill.

## Idempotency and reruns

- Every row's idempotency key derives from stable per-record timestamps
  (an item's `last_observed_at`, a collection's
  `mapping_last_observed_at`), so rerunning the backfill writes nothing
  new and never rewrites a stored payload.
- The backfill also advances each item's diff baseline (`last_snapshot`)
  to the published snapshot, so the item's next live refresh publishes
  only real changes instead of re-discovering the item.
- Because the first live refresh after the backfill may observe
  adapter-computed fields the database did not hold (for example a GitHub
  issue's project or label tags), that first refresh can emit a small
  number of `source_changed` observations as those fields become known.
  Subsequent refreshes diff normally.

## Skipped records

Items and memberships without an `external_id` cannot be identified in
the contract and are counted as skipped in the summary rather than
published with a malformed identity.
