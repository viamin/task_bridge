# TaskBridge Web baseline backfill

Before enabling TaskBridge Web publication, seed the local outbox with the
current synchronized state:

```sh
bundle exec rake task_bridge:outbox:backfill DRY_RUN=1
bundle exec rake task_bridge:outbox:backfill
```

The dry run does not write local records and prints counts by service,
mapping confidence, and incomplete records. The write command backfills source
provenance where required, emits one baseline `item` snapshot per source item,
and emits mappings only for high (`confirmed`) and medium (`inferred`)
confidence memberships. Low-confidence mappings are withheld and reported by
the dry run.

Baseline rows have `provenance.detected_by: backfill` and `backfilled_at`; they
are not historical change events and do not create `snapshot_seen` or
`sync_run` rows. The operation writes only TaskBridge's local database and
never calls source services. It is safe to rerun: stable observed timestamps
and outbox idempotency keys reuse the existing entries.
