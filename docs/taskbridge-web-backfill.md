# TaskBridge Web baseline backfill

Before enabling TaskBridge Web publication for an existing installation, seed its
outbox with the current local sync state:

```sh
bundle exec rake task_bridge:backfill_observations DRY_RUN=true
bundle exec rake task_bridge:backfill_observations
```

The dry run writes one JSON summary to stdout and makes no database or external
source changes. It reports item counts by service, mapping counts by confidence,
and incomplete items that were skipped. Review `withheld_low_confidence` before
continuing: local low-confidence/title-derived mappings are intentionally not
published. They remain in `sync_collections` for manual cleanup.

The real run only writes local provenance, baseline snapshots, and pending
outbox rows. It never calls a source adapter or mutates an external system. It
emits one `item` current-state snapshot per complete existing item, sets its
local diff baseline, and emits mapping rows only for confirmed or inferred
memberships. The baseline payload has `provenance.detected_by: "backfill"` and
`backfilled_at`; it does not create `snapshot_seen` observations or sync-run
rows.

The command is safe to rerun. Its timestamps come from the stored first
observation/mapping data, so the resulting idempotency keys are stable and the
outbox deduplicates existing rows. After reviewing the summary, enable normal
publication and run the usual outbox publisher.
