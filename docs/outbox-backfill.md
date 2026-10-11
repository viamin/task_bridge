# Outbox baseline backfill

Before enabling TaskBridge Web publication for an existing TaskBridge
installation, seed the local outbox with the synchronized current state:

```sh
bundle exec rake task_bridge:outbox:backfill DRY_RUN=true
bundle exec rake task_bridge:outbox:backfill
```

The dry run writes nothing and prints JSON counts for item snapshots by source
service, mapping rows by confidence, and skipped records. Review
`mappings.skipped.low_confidence`: title-derived or otherwise low-confidence
mappings are deliberately not published. They remain in local `sync_collections`
for manual cleanup or later review.

The task first fills missing local source and mapping provenance, then enqueues
one `item` current-state snapshot per synchronized item and confirmed/inferred
mapping memberships. Snapshots carry `provenance.detected_by: "backfill"` and a
stable `backfilled_at` timestamp. It creates no `observation` or `sync_run`
rows, and never contacts or mutates an external source system.

It is safe to rerun: observation times are derived from stable local timestamps,
and the outbox's deterministic idempotency keys preserve the original rows.
