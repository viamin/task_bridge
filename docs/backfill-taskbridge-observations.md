# Backfilling TaskBridge Web baselines

Before enabling TaskBridge Web publication for an existing installation, run:

```sh
bundle exec rake task_bridge:backfill_sync_provenance DRY_RUN=1
bundle exec rake task_bridge:backfill_sync_provenance
```

The dry run writes no database rows and prints JSON counts by source service,
mapping confidence, and skipped records. Resolve records without an external
ID before the real run. Low-confidence (`low`/`tentative`) memberships are
reported as skipped and deliberately are not enqueued; `high` and `medium`
mappings become `confirmed` and `inferred` rows respectively.

The real run only writes local TaskBridge provenance, baseline snapshots, and
outbox rows. It never calls external source APIs or changes source systems.
It is safe to rerun: stable observation timestamps and outbox idempotency keys
reuse existing entries. It emits item snapshots marked with backfill provenance,
not historical `snapshot_seen` observations, and emits no synthetic sync-run
rows. Enable TaskBridge Web publication only after reviewing the dry-run output
and completing the real run.
