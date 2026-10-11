# Outbox Baseline Backfill (TaskBridge Web Seeding)

- Issue: #222
- Parent epic: #214
- Contract: [RDR 215](rdr-215-taskbridge-observation-publication-contract.md)

Existing `sync_items` and `sync_collections` represent real synchronized
work. The baseline backfill turns that existing data into the outbox rows
TaskBridge Web needs to seed its current-state projections, so only rows
published *after* the backfill are treated as change history.

## What the backfill writes

| Row kind | Source | Notes |
| --- | --- | --- |
| `item` | one per `sync_items` row with an `external_id` | Baseline current-state snapshot. Marked `provenance.detected_by: "backfill"` plus `provenance.backfilled_at`; never emitted as a `snapshot_seen` observation. |
| `mapping` | one per `sync_collections` membership | Published only for `mapping_confidence` `high` (→ `confirmed`) and `medium` (→ `inferred`). |
| `sync_run` | none | `sync_service_states` has no reliable per-run start/end timestamps; live sync runs publish these going forward. |

Decisions recorded during #222 (resolving RDR 215's open backfill
question and related clarifications):

- **Low-confidence mappings are withheld**, not published as `tentative`.
  They stay identifiable for manual cleanup through the dry-run summary's
  counts by confidence and method. When the product owner decides how to
  handle them, a later upgrade re-runs naturally: raising a collection's
  confidence during sync publishes a new mapping fact.
- **No `snapshot_seen` observation rows** come from the backfill. The
  first live refresh of each item after the backfill emits that item's
  first genuine live observation.
- **Single-instance services use a permanent default instance token**
  (for example `omnifocus:default`) in `source.service_instance`, so
  backfilled and live rows share identities. This token is embedded in
  idempotency keys and can never change.

## Safety properties

- **Idempotent.** Every row's idempotency key embeds a stable
  `observed_at` (the item's `last_observed_at`, or the collection's
  `mapping_last_observed_at`), so rerunning the task re-finds stored rows
  instead of duplicating them. Rerun it as often as needed.
- **No external mutation.** The backfill only inserts `OutboxEntry`
  rows. It never contacts provider APIs and never mutates external source
  systems.
- **Publication stays gated.** Rows sit `pending` in the outbox until
  `task_bridge.web.enabled` turns on publication (see
  `config/settings.yml`); the backfill itself never sends anything.

## How to run it

Run the dry run first to review counts by service, confidence, and
method, plus skipped/incomplete records:

```bash
bundle exec rake task_bridge:outbox:backfill_baseline_dry_run
```

Example output:

```
Baseline backfill (dry run):
  items: 12 considered, 10 enqueued, 2 skipped (no external id)
  items by service: asana=4 enqueued/0 skipped, github=3 enqueued/0 skipped, google_tasks=1 enqueued/1 skipped, omnifocus=2 enqueued/1 skipped
  mappings: 5 collections, 9 memberships, 7 enqueued, 2 withheld (low confidence), 0 skipped (no external id)
  mappings by confidence: high=5, low=2, medium=2
  mappings by method: manual_backfill=2, source_sync_id=5, title_fallback=2
```

The dry run never writes. If it warns that provenance is still pending,
run `bundle exec rake task_bridge:backfill_sync_provenance` (or just run
the full backfill, which runs it first) — until identity/mapping
provenance is backfilled, unresolved mappings count as `unknown` and are
withheld.

Then run the real backfill:

```bash
bundle exec rake task_bridge:outbox:backfill_baseline
```

The task first runs the idempotent identity/provenance backfill
(#216/#217) so `source_service_name` / `source_service_instance` and
mapping confidence are resolved, then enqueues the baseline rows. It is
safe to run multiple times and safe to re-run after interruptions.

## After the backfill

1. Review withheld low-confidence memberships (from the dry-run counts)
   and clean them up locally if desired — fixing the underlying
   `sync_collection` mapping evidence, or letting the next sync upgrade
   provenance.
2. Optionally preview the exact batches that would be sent, without
   sending anything:

   ```bash
   bundle exec rake task_bridge:outbox:publish_dry_run
   ```

3. Enable TaskBridge Web publication (`task_bridge.web.enabled` plus
   `base_url` / `api_key` in `config/settings.yml` or the
   `TASK_BRIDGE_WEB_*` environment variables) and let the hourly sync —
   or `bundle exec rake task_bridge:outbox:publish` — deliver the
   baseline rows before later change history.
