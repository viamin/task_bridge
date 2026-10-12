# TaskBridge Web baseline backfill

Before enabling TaskBridge Web publication for an existing TaskBridge install,
seed the local outbox with its current synchronized state:

```sh
DRY_RUN=1 bundle exec rake task_bridge:backfill_observations
bundle exec rake task_bridge:backfill_observations
```

The dry run changes nothing. It prints item counts by source service, mapping
membership counts by confidence, and skipped/incomplete counts. Review any
`mappings.low_confidence` count before publication: low-confidence,
title-derived/manual mappings are intentionally withheld from TaskBridge Web.

The real command only changes TaskBridge's local provenance, mapping metadata,
and outbox tables; it never contacts or mutates source systems. It writes one
baseline `item` snapshot for each known item, tagged with
`provenance.detected_by: backfill` and `backfilled_at`. It does not create
historical observation events or approximate `sync_run` records.

The command is safe to rerun. Its item and mapping rows use stable observed
timestamps and deterministic idempotency keys, so existing outbox rows are
reused. Single-instance sources use the permanent `<service>:default` identity
segment; named source instances retain their configured name.

Only after reviewing the dry-run output should publication be enabled through
the existing TaskBridge Web settings and a normal sync/publication run.
