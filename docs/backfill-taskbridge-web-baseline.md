# Backfilling the TaskBridge Web baseline

Before enabling publication to TaskBridge Web (RDR #215, `task_bridge.web.enabled`),
run the baseline backfill so TaskBridge Web starts from your known current state and
only later diffs are treated as change history.

The backfill is idempotent and local-only: it reads `sync_items`,
`sync_collections`, and `sync_service_states`, writes rows into the local
outbox, and never mutates external source systems. It is safe to run
repeatedly and safe to interrupt — every row is keyed by a deterministic
idempotency key derived from the record's own observation timestamps, so a
rerun finds existing rows instead of duplicating them.

## What the backfill writes

- One `item` snapshot row per existing `sync_items` row (skipping rows
  without an `external_id`, which are counted as skipped/incomplete in the
  summary). Item rows are marked as baseline state — not historical change
  events — via payload provenance: `provenance.detected_by: "backfill"` plus
  a `backfilled_at` timestamp. The backfill emits **no** `snapshot_seen`
  observation rows.
- One `mapping` row per existing `SyncCollection` membership:
  - `high` confidence (sync-id or created-by-sync evidence) publishes as
    `confirmed`;
  - `medium` confidence (title-derived) publishes as `inferred`;
  - `low` confidence (or not-yet-inferred) mappings are **withheld** — they
    are not enqueued, and are instead listed in the dry-run summary so they
    can be reviewed or cleaned up manually. This implements RDR #215's
    safer default; whether TaskBridge Web should ever receive `tentative`
    baseline mappings remains an open product decision.
- No `sync_run` rows: `sync_service_states` has no reliable per-run
  start/end timestamps, and the contract requires them. Live sync runs
  publish summaries going forward once publication is enabled.

`service_instance` defaults to a permanent `:default` token for services
configured without an instance suffix (for example `omnifocus:default`,
`google_tasks:default`), matching the live observation pipeline so
backfilled and live rows share item identities. That token is embedded in
idempotency keys and can never change.

## Running the backfill

```bash
# Optional but recommended first: backfill source identity/provenance
# fields so the dry-run summary is fully accurate. The real backfill runs
# this step automatically when it has not been done.
bundle exec rake task_bridge:backfill_sync_provenance

# Preview: prints counts by service and mapping confidence, plus the
# skipped/incomplete records and withheld low-confidence collections.
# Writes nothing.
bundle exec rake task_bridge:outbox:backfill_baseline_dry_run

# Backfill: enqueues the baseline rows into the local outbox and prints
# the same summary. Rerunning is safe: existing rows are left untouched
# and counted as "already present".
bundle exec rake task_bridge:outbox:backfill_baseline
```

Verify the pending baseline before publishing:

```bash
# Render the exact batches that would be sent (NDJSON on stdout).
bundle exec rake task_bridge:outbox:publish_dry_run
```

Then enable publication (`task_bridge.web.enabled: true` plus `base_url`
and `api_key` in settings) and let the regular
`task_bridge:outbox:publish` task (or the next sync run) deliver the
baseline to TaskBridge Web.

## Reading the summary

```
TaskBridge outbox baseline backfill
Items: 7 candidates, 6 enqueued, 0 already present, 1 skipped (missing external id)
  By service: asana=1, github=1, google_tasks=2, omnifocus=2
Mappings: 3 collections, 3 enqueued, 0 already present, 2 withheld (low confidence)
  By confidence: confirmed=2, inferred=1
  Withheld low-confidence collections (review before cleanup): #12 "Stale guess"
```

- `already present` counts rows a previous backfill run already enqueued;
  on a rerun every count should move from `enqueued` to `already present`.
- `withheld` counts low-confidence memberships that were not published.
  The listed collections are the manual-cleanup backlog: either confirm
  the mappings (for example by letting a sync run upgrade the evidence) or
  remove them, then rerun the backfill — upgraded collections enqueue
  their mapping rows at that point.

## Notes

- A dry run against data that has not had the provenance backfill applied
  reports collections without mapping metadata as withheld, because the
  real run backfills that metadata first. Run
  `task_bridge:backfill_sync_provenance` before the dry run for an exact
  preview.
- The backfill does not touch `last_snapshot` on `sync_items`; that column
  is the live change-detection baseline (#219) and starts empty so the
  next live refresh of each item is still detected normally.
- Delivered outbox rows are pruned after the configured retention window
  (`task_bridge.outbox.retention`); TaskBridge Web owns durable history.
