# TaskBridge Web baseline backfill

Run the baseline backfill after deploying the provenance and outbox migrations,
but before enabling TaskBridge Web publication. It only writes TaskBridge's local
database and never calls an external source service.

Preview the exact scope first:

```sh
DRY_RUN=1 bundle exec rake task_bridge:backfill_outbox
```

The preview prints item counts by service, mapping counts by confidence, and
skipped or incomplete records. Low-confidence (`low` / `tentative`) mappings
are listed as `low_withheld`; they are intentionally not queued for TaskBridge
Web and remain available for later local cleanup.

When the output is acceptable, enqueue the baseline:

```sh
bundle exec rake task_bridge:backfill_outbox
```

The task is idempotent. It creates one current-state `item` snapshot per known
source item and mapping rows only for high (`confirmed`) and medium (`inferred`)
confidence memberships. Snapshots carry `provenance.detected_by: backfill` and
`backfilled_at`; no historical observation or sync-run rows are invented.
