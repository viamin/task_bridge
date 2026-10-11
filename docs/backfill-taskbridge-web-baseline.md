# Backfilling the TaskBridge Web baseline (#222)

TaskBridge Web starts from known current state and only treats later diffs as
change history. Before enabling publication (RDR #215, issue #221), run the
baseline backfill so existing `sync_items` and `sync_collections` appear in the
outbox as baseline rows — not as historical change events.

## What the backfill writes

- One `item` snapshot row per existing `sync_items` row (the item's
  `normalized_snapshot`), marked as baseline via
  `provenance.detected_by: "backfill"` and a `backfilled_at` timestamp.
  No `snapshot_seen` observation rows are written by the backfill; live syncs
  publish observations going forward (#219).
- One `mapping` row per `sync_collection` membership, also marked as baseline.
  Only memberships at `confirmed`/`inferred` confidence (internal `high` /
  `medium`) are enqueued. `low`/`tentative` memberships are withheld from
  publication per the product decision on #222 and are identifiable through
  the dry-run summary counts by confidence instead. Resolve them locally
  (e.g. re-sync so a sync-id match upgrades the mapping) and rerun.
- No `sync_run` rows: `sync_service_states` has no reliable per-run start/end
  timestamps, and RDR #215 only allows backfilled sync-run summaries where
  reliable timestamps exist. Normal sync runs publish them going forward.

The backfill is write-local only. It never instantiates a provider service, so
it cannot mutate an external source system, and it never publishes — rows stay
`pending` in the outbox until `rake task_bridge:outbox:publish` sends them.

## How to run it

```bash
# Preview: summarize counts by service, confidence, and skipped/incomplete
# records without writing anything.
bundle exec rake task_bridge:outbox:backfill_baseline_dry_run

# Backfill (also runs the identity/provenance backfill from #216/#217 first):
bundle exec rake task_bridge:outbox:backfill_baseline

# Inspect what is queued before any of it leaves the machine:
bundle exec rake task_bridge:outbox:publish_dry_run
```

Both backfill steps are idempotent: every row's idempotency key is derived
from stable, item-derived timestamps (`last_observed_at`,
`mapping_last_observed_at`), never from the wall clock of the run, so reruns
re-find the stored rows instead of duplicating them. Rerun the task as often
as needed — for example after fixing low-confidence mappings.

## Baselines and later diffs

For each item without a stored `last_snapshot`, the backfill seeds the live
pipeline's diff baseline after its snapshot row is enqueued. The next live
refresh of that item therefore emits only real changes instead of re-publishing
a discovery `snapshot_seen`. Items the live pipeline already tracks keep their
existing baseline untouched.

## Service instances

Rows for services without a configured instance (OmniFocus, Reminders, ...)
use the permanent default token `<service_type>:default` (e.g.
`omnifocus:default`), matching the RDR #215 identity examples. The token is
embedded in idempotency keys and can never be renamed; the live pipeline uses
the same default so backfilled and live rows share identities.

## After the backfill

1. Review the dry-run and outbox previews above; low-confidence memberships
   appear only in the dry-run summary.
2. Configure TaskBridge Web (`task_bridge.web.enabled`, `base_url`, `api_key`
   in `config/settings.yml`) — publication stays disabled until you opt in.
3. Publish the baseline: `bundle exec rake task_bridge:outbox:publish`.
4. Leave the hourly launchd/`task_bridge` flow running: live syncs keep the
   outbox current from here on.
