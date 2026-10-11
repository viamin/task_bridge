# Outbox Backfill for TaskBridge Web

- Issue: #222
- Parent: #214
- Depends on: #216, #217, #218 (source identity/provenance columns,
  normalized snapshots, local observation outbox)
- Contract: RDR #215 (`docs/rdr-215-taskbridge-observation-publication-contract.md`),
  "Migration and Backfill Implications"

Existing `sync_items` and `sync_collections` represent real synchronized
work. The outbox backfill (`Outbox::Backfill`) seeds the local outbox
from that data so TaskBridge Web can start from a known current state and
treat only later diffs as change history. It is a read-only pass over
local tables: it never contacts a provider and never mutates external
source systems.

## What it publishes

- **One baseline `item` snapshot per existing sync item** (`record_kind:
  item`), built entirely from persisted columns (STI type via the item's
  provider, `external_id`, `url`, `last_modified`, and the captured
  service instance name). Each row is marked
  `provenance.detected_by: "backfill"` and carries a `backfilled_at`
  timestamp so it can never be mistaken for a historical change event.
- **One `mapping` row per existing `SyncCollection` membership**
  (`record_kind: mapping`), translating local confidence to the contract
  enum: `high` → `confirmed`, `medium` → `inferred`, `low` → `tentative`.
- **No `observation` rows and no `sync_run` rows.** Baselines are item
  snapshots, not `snapshot_seen` observations, and `sync_service_states`
  has no reliable per-run start/end timestamps, so live sync runs publish
  sync-run summaries going forward instead.

`notes_preview` is omitted (per-source notes export is disabled by
default), and item snapshots omit the optional `sync_collection` block
because memberships — and their confidence gating — are published as
separate mapping rows.

## Low-confidence mappings are withheld

Low-confidence (`low`/`tentative`, e.g. title-derived or manual-backfill)
memberships are **not enqueued for publication**. They remain identifiable
through the dry-run summary's `withheld by confidence` counts for local
review or manual cleanup. This resolves RDR #215's open question in favor
of the RDR's stated default; whether TaskBridge Web should ever receive
`tentative` backfilled mappings remains an explicit decision point for the
product owner, and the withhold-by-default behavior can be revisited
without migration (simply rerun the backfill once the policy changes).

## What it writes

- New rows in `outbox_entries` (its only publication-side effect).
- The idempotent local provenance preparation from #218
  (`task_bridge:backfill_sync_provenance`) runs first so identities and
  mapping confidences exist before they are read. The dry run applies
  this preparation too, so its counts match a subsequent real run.
- Nothing else: it does not advance `sync_items.last_snapshot` diff
  baselines (a locally partial baseline could fabricate `source_changed`
  transitions), does not touch provider data, and never rewrites item
  columns.

## Rerun safety

Every idempotency key is derived from each row's own data — items from
`last_observed_at` (falling back to `last_modified`/`updated_at`),
memberships from `mapping_last_observed_at` (falling back to the
collection's `updated_at`) — never from the wall clock, so reruns rebuild
the same keys and dedupe through the outbox's unique index. Running the
backfill repeatedly is safe and converges to the same rows.

One caveat: `backfilled_at` records when the run executed. If a delivered
row is pruned after its retention window and a rerun later re-enqueues
the same (unchanged) fact, the new row's payload differs in that field
and TaskBridge Web would reject it as a duplicate-key conflict. Treat a
conflicting backfilled row as operator-reviewable, not data loss — the
fact was already accepted.

## Running the backfill

Run the backfill **before** enabling publication to TaskBridge Web
(`task_bridge.web.enabled` in `config/settings.yml`, off by default) so
baseline rows are pending in the outbox when the publisher first runs:

```bash
# 1. Preview: summarize counts by service, confidence, and skipped
#    records without writing any outbox rows.
bundle exec rails task_bridge:outbox:backfill_dry_run

# 2. Backfill: enqueue the baseline rows, then review the same summary.
bundle exec rails task_bridge:outbox:backfill

# 3. Publish the pending rows (or enable task_bridge.web.enabled and let
#    the scheduled run publish them).
bundle exec rails task_bridge:outbox:publish
```

Both tasks print the same summary:

```
Outbox backfill
  item snapshots:
    enqueued by service: asana=12, github=8, google_tasks=5, omnifocus=41
    already enqueued (deduped) by service: none
    skipped (service/reason): omnifocus/missing_external_id=2
  mapping rows:
    enqueued by confidence: confirmed=19, inferred=6
    already enqueued (deduped) by confidence: none
    withheld by confidence (not published; review locally): low=4
    skipped (reason): collection_without_members=1
```

Skipped item counts are keyed by `service/reason` (missing external IDs,
rows whose STI type no longer resolves); skipped or withheld memberships
appear under `mapping rows`. Rows whose enqueue transiently fails
(a busy SQLite lock, retried and then dropped) are counted as
`enqueue_failed` — rerun the backfill to retry them.

After the backfill, the live observation pipeline (#219-#221) takes
over: each item's first live refresh emits its own `snapshot_seen`
discovery observation, and later refreshes emit only real
`source_changed` transitions on top of the backfilled current state.
