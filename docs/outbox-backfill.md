# Outbox baseline backfill

Before enabling TaskBridge Web publication for an existing installation, seed
the local outbox with the current synchronized state:

```sh
bundle exec rake task_bridge:backfill_sync_provenance
```

The task first fills missing source provenance and collection mapping metadata,
then writes one baseline `item` snapshot per synchronized item and mapping rows
for high- and medium-confidence memberships. It writes no observations or
sync-run rows, does not contact external services, and records baseline
snapshots with `provenance.detected_by: backfill` and `backfilled_at` metadata.
It also seeds each item's local snapshot baseline, so later source changes are
the first change-history observations.

Preview without writing database rows:

```sh
DRY_RUN=true bundle exec rake task_bridge:backfill_sync_provenance
```

Both forms print JSON counts by service, mapping confidence, and skipped
records. Low-confidence (`tentative`) memberships are intentionally withheld;
their skipped count is the review queue. The operation is safe to rerun:
source timestamps and outbox idempotency keys are stable, so existing rows are
reused.
