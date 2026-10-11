# TaskBridge Web outbox backfill

Before enabling TaskBridge Web publication for an existing deployment, seed the
local outbox once:

```sh
bundle exec rake task_bridge:backfill_outbox DRY_RUN=1
bundle exec rake task_bridge:backfill_outbox
bundle exec rake task_bridge:outbox:publish
```

The dry run makes no database changes and prints JSON counts by source service,
mapping confidence, and skipped/incomplete records. The write run is idempotent:
it uses stable observed timestamps and outbox idempotency keys, so it can be
repeated safely. It never calls an external source system.

Backfilled `item` rows are current-state baselines, marked with
`provenance.detected_by: backfill` and `backfilled_at`; they are not historical
change observations. No `snapshot_seen` or `sync_run` rows are created.

Only high/confirmed and medium/inferred memberships are added to the outbox.
Low-confidence/title-derived memberships remain withheld and are counted in the
dry-run summary for manual cleanup or review.
