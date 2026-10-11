# TaskBridge Web baseline backfill

Before enabling TaskBridge Web publication, seed its outbox with the current
state already held by TaskBridge:

```sh
DRY_RUN=true bundle exec rake task_bridge:backfill_outbox_baseline
bundle exec rake task_bridge:backfill_outbox_baseline
```

The dry run performs no writes and prints JSON counts by source service, mapping
confidence, and skipped/incomplete records. The real run first fills missing
source and mapping provenance, then emits one baseline `item` snapshot per
known item and mapping rows only for confirmed or inferred memberships.

Baseline snapshots include `provenance.detected_by: backfill`, `baseline: true`,
and `backfilled_at`; they are current-state records, not historical
`snapshot_seen` observations. Low-confidence/tentative mappings are withheld
and appear in the dry-run `skipped.low_confidence_mappings` count. No sync-run
rows are generated because historical run timestamps are not reliable.

The task only reads local TaskBridge records and writes local provenance,
baseline, and outbox data. It never calls or mutates an external source system.
Rerunning it is safe: deterministic idempotency keys preserve the original
outbox rows, and existing baseline snapshots are not replaced.
