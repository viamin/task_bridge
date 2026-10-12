# TaskBridge Web baseline backfill

Before enabling TaskBridge Web publication for an existing deployment, seed its
local outbox with current-state records:

```sh
BACKFILL_DRY_RUN=1 bundle exec rake task_bridge:backfill_sync_data
bundle exec rake task_bridge:backfill_sync_data
```

The dry run writes no database rows and prints JSON counts for snapshots by
service, mappings by confidence, and incomplete/skipped records. The live task
only updates local TaskBridge provenance and outbox data; it never calls an
external source system and does not publish HTTP requests. Run the normal
outbox publisher after reviewing the dry-run report.

Each known item gets one `item` current-state snapshot with
`provenance.detected_by: "backfill"`, `provenance.baseline: true`, and a stable
`backfilled_at` timestamp. The task deliberately creates no `snapshot_seen`
observations and no synthetic `sync_run` rows, so a baseline is never presented
as historical change activity.

Reruns are safe: source observation timestamps and outbox idempotency keys are
stable. Confirmed (`high`) and inferred (`medium`) collection memberships are
seeded. Low-confidence (`low`/tentative) title or manual mappings are withheld
from TaskBridge Web and reported by the dry-run summary for later review.
