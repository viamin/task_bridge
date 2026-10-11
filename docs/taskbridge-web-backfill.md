# TaskBridge Web baseline backfill

Run this once after deploying the outbox schema and before enabling
`task_bridge.web.enabled`. The task only reads existing synchronized records
and writes local provenance, mapping metadata, snapshots, and pending outbox
entries. It never calls an external source system or TaskBridge Web.

Preview the work first:

```sh
DRY_RUN=1 bundle exec rake task_bridge:backfill_outbox_baseline
```

The JSON summary groups item rows by service and memberships by confidence. It
also reports incomplete items and low-confidence mappings held back from
publication. Low-confidence mappings are deliberately not enqueued; high maps
to `confirmed` and medium maps to `inferred`.

Then write the local baseline:

```sh
bundle exec rake task_bridge:backfill_outbox_baseline
```

Each existing item receives one current-state `item` row with `baseline: true`,
`detected_by: backfill`, and `backfilled_at` provenance. The task emits no
historical observations and no `sync_run` rows. It is safe to rerun: its
observed timestamps and outbox idempotency keys are stable, and existing rows
are reused. Once the output is reviewed, enable publication through the normal
`task_bridge.web.enabled` setting.
