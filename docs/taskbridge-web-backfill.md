# TaskBridge Web baseline backfill

Run the backfill after deploying the provenance and outbox migrations, and before enabling TaskBridge Web publication. It only reads local TaskBridge records and writes local provenance, snapshot baselines, and pending outbox rows; it never calls or mutates an external task provider.

Preview the result first:

```sh
bundle exec rake task_bridge:outbox:backfill DRY_RUN=1
```

The preview reports item counts by service, mapping counts by confidence, and incomplete or withheld records. Run the same command without `DRY_RUN=1` to create durable baseline item rows. Re-running it is safe: rows use the same idempotency keys and existing snapshots are retained.

The backfill creates one current-state `item` row per item and marks it with `provenance.detected_by: "backfill"` and `baseline: true`. It intentionally creates no `snapshot_seen`, source-change, deletion, or sync-run observations. It records a snapshot baseline so the next normal sync reports only later differences.

Mappings with high confidence publish as `confirmed`; medium confidence publishes as `inferred`. Low-confidence mappings are withheld from publication and are listed as `skipped.mappings.low` in the dry-run output for manual cleanup or review. Once the output is acceptable, enable the regular outbox publisher:

```sh
bundle exec rake task_bridge:outbox:publish
```
