# TaskBridge Web baseline backfill

Before enabling `task_bridge.web.enabled`, seed the local outbox from existing
sync data:

```sh
bundle exec rails task_bridge:backfill_observations DRY_RUN=true
bundle exec rails task_bridge:backfill_observations
```

The dry run makes no database changes and prints item, mapping, low-confidence,
and incomplete-record counts grouped by service and mapping confidence. Review
the low-confidence counts before deciding how to correct those local mappings.

The non-dry run first fills missing source provenance and mapping metadata, then
enqueues one `item` current-state snapshot per complete source item. Snapshot
payloads are marked `provenance.detected_by: backfill` and
`provenance.initial_observation: true`; it creates no synthetic observation or
sync-run events. Mapping rows are emitted only for high (`confirmed`) and medium
(`inferred`) confidence memberships. Low (`tentative`) mappings are withheld
from TaskBridge Web and remain visible in the dry-run summary for cleanup.

The task is idempotent: its baseline timestamps are derived from persisted
source/collection timestamps, so rerunning it reuses the existing outbox
idempotency keys. It only writes TaskBridge's database and never contacts an
external source system.
