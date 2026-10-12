# TaskBridge Web baseline backfill

Run the baseline backfill after deploying the outbox migrations and before enabling
`task_bridge.web.enabled`. It only reads local TaskBridge data and writes local
provenance, baseline, and outbox records; it never contacts a source service.

Preview the records and withheld mappings first:

```sh
DRY_RUN=1 bundle exec rake task_bridge:backfill_outbox
```

The JSON summary reports item counts by service, membership counts by confidence,
withheld low-confidence mappings, and incomplete records. Low-confidence (`low` /
`tentative`) memberships are intentionally withheld for later cleanup or Web-side
review. `high` maps to `confirmed`, and `medium` maps to `inferred`.

Then seed the local outbox:

```sh
bundle exec rake task_bridge:backfill_outbox
```

Each source item receives one baseline `item` snapshot with `baseline: true` and
`provenance.detected_by: backfill`; no `snapshot_seen` or sync-run rows are created.
The task records the normalized snapshot as the local diff baseline, so subsequent
syncs publish only later changes. It is safe to rerun: stable observed timestamps and
outbox idempotency keys prevent duplicate rows. Single-instance services use the
permanent `<service>:default` identity.

After reviewing the output, enable publication and run the existing publisher:

```sh
bundle exec rake task_bridge:outbox:publish
```
