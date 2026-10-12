# TaskBridge Web baseline backfill

Before enabling TaskBridge Web publication for an existing installation, preview
the local baseline:

```sh
DRY_RUN=true bundle exec rake task_bridge:backfill_sync_data
```

The output groups item snapshots by service and mappings by confidence, and
lists skipped records. Low-confidence (`low` / tentative) memberships are
listed as skipped and are not published; review them manually before a later
sync establishes stronger evidence.

Run the backfill after reviewing the preview:

```sh
bundle exec rake task_bridge:backfill_sync_data
```

It only writes TaskBridge's database/outbox and does not contact source
services. It emits one baseline `item` snapshot per existing source item and
mapping rows for high/medium-confidence memberships. The snapshot provenance
is marked `detected_by: backfill`, `baseline: true`, and `backfilled_at`; no
historical observation or sync-run rows are invented. Re-running is safe:
stable observed timestamps produce the same idempotency keys.
