# TaskBridge Web baseline backfill

Before enabling `task_bridge.web.enabled`, seed TaskBridge Web's current state:

```sh
bundle exec rake task_bridge:outbox:backfill DRY_RUN=1
bundle exec rake task_bridge:outbox:backfill
```

The preview makes no database or external-source changes. Its JSON summary groups
item snapshots by service, mappings by confidence, and skipped or withheld records.

The real task only updates TaskBridge's local provenance, snapshot baseline, and
outbox. It never calls a source provider. It is safe to rerun: source observation
times and outbox idempotency keys are stable, and already-enqueued rows are reused.

One baseline `item` snapshot is queued for every existing item with an external ID.
It has `provenance.detected_by: "backfill"`, `provenance.baseline: true`, and a
`backfilled_at` timestamp. The task does not create `snapshot_seen` observations or
synthetic sync runs, so baseline state is never represented as historical change.

Mappings with `high` confidence publish as `confirmed`; `medium` mappings publish
as `inferred`. `low`/tentative mappings are withheld and counted in the summary for
manual cleanup or later review.
