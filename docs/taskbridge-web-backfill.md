# TaskBridge Web baseline backfill

Run the baseline backfill after deploying the observation/outbox schema and before enabling TaskBridge Web publication. It reads local TaskBridge state only; it never contacts or mutates provider systems.

Preview the work first:

```sh
bundle exec rake task_bridge:backfill_sync_provenance_dry_run
```

The JSON summary reports item counts by service, mapping memberships by confidence, and skipped records. In particular, low-confidence (`low` / `tentative`) mappings are reported as skipped and are not published. Review them locally before resolving their mapping evidence.

Then create the baseline outbox rows:

```sh
bundle exec rake task_bridge:backfill_sync_provenance
```

The task records a deterministic baseline item snapshot for each synchronized item and advances its local diff baseline. Snapshot payloads have `provenance.detected_by: "backfill"`, `provenance.baseline: true`, and a stable `backfilled_at` value. It does not create `snapshot_seen` observations or `sync_run` records, so the baseline is not presented as historical change activity; later sync differences become the first change history.

The task is safe to rerun: source provenance is filled only where absent and outbox idempotency keys prevent duplicate baseline snapshots and mapping rows. Once the pending outbox rows look correct, enable normal publication with `bundle exec rake task_bridge:outbox:publish`.
