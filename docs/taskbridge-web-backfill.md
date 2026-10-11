# TaskBridge Web baseline backfill

Before enabling TaskBridge Web publication, seed the local outbox from the
current synchronized state:

```sh
bundle exec rake task_bridge:outbox:backfill
```

This task first fills missing source provenance and mapping evidence, then
enqueues one baseline `item` snapshot for each known source item. Baseline
snapshots are marked with `provenance.detected_by: "backfill"` and
`provenance.backfilled_at`; they are not `snapshot_seen` observations and do
not claim a historical change occurred. The task emits no `sync_run` rows.

Preview the service, confidence, and skipped-record counts without changing
the database:

```sh
DRY_RUN=true bundle exec rake task_bridge:outbox:backfill
```

The JSON summary groups item counts by service, mapping counts by confidence,
and skipped/incomplete records by reason. High-confidence mappings publish as
`confirmed`; medium-confidence mappings publish as `inferred`. Low-confidence
or incomplete mappings are withheld and counted in `skipped` for later manual
cleanup or review.

The task is safe to rerun: it uses the known observation and mapping timestamps
to generate stable outbox idempotency keys. It only writes TaskBridge's local
database and never contacts source systems. After reviewing the dry run and
pending outbox rows, enable publication and run the normal publisher:

```sh
bundle exec rake task_bridge:outbox:publish
```
