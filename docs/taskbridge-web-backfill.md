# TaskBridge Web baseline backfill

Before enabling `task_bridge.web.enabled`, seed the local outbox with the
current state already synchronized by TaskBridge:

```sh
bundle exec rake task_bridge:outbox:backfill_dry_run
bundle exec rake task_bridge:outbox:backfill
bundle exec rake task_bridge:outbox:publish_dry_run
```

The backfill is safe to rerun. It first fills local source and mapping
provenance, then creates one deterministic `item` snapshot per source item and
sets its local comparison baseline. The snapshot carries `provenance.detected_by =
backfill` and `backfilled_at`; it does not create `snapshot_seen` observations
or sync-run rows.

Dry-run output is JSON with counts by item service, published mapping confidence,
withheld mapping confidence, and skipped incomplete records. Low-confidence
(`low`/`tentative`) mappings are deliberately withheld from TaskBridge Web and
remain visible in that summary for manual cleanup. High mappings publish as
`confirmed`; medium mappings publish as `inferred`.

Review the dry-run totals, run the write task, use `publish_dry_run` to inspect
the pending payloads, and only then enable publication. The tasks only read
existing local sync data and write local provenance/outbox state; they never
contact or mutate external source systems.
