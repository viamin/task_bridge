# TaskBridge Web baseline backfill

Run this once after applying the observation-pipeline migrations and before
enabling TaskBridge Web publication. It reads TaskBridge's local sync data
only; it never calls or mutates a source system.

Preview the work first:

```sh
bundle exec rake task_bridge:backfill_outbox_baseline DRY_RUN=1
```

The JSON report groups item snapshots by service and mappings by confidence,
and lists incomplete rows. Low-confidence mappings are intentionally
withheld; their count appears under `withheld_mappings_by_confidence` for
manual cleanup or review.

When the report is acceptable, seed the local outbox:

```sh
bundle exec rake task_bridge:backfill_outbox_baseline
```

The task first fills missing local source and mapping provenance, then creates
one current-state item row per source item and mapping rows only for confirmed
or inferred memberships. Item payloads carry `provenance.detected_by` of
`backfill`, `baseline: true`, and `backfilled_at`; no historical observation
or sync-run rows are fabricated. Re-running the task is safe: deterministic
idempotency keys retain the original outbox rows and existing snapshot
baselines are not overwritten. Enable publication only after the outbox has
been reviewed with `bundle exec rake task_bridge:outbox:publish_dry_run`.
