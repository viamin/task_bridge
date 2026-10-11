# Baseline outbox backfill

Before enabling TaskBridge Web publication for an existing TaskBridge installation,
seed its local outbox with the current synchronized state:

```sh
bundle exec rake task_bridge:backfill_outbox_baseline
```

Preview the counts without writing provenance, snapshots, or outbox rows:

```sh
DRY_RUN=true bundle exec rake task_bridge:backfill_outbox_baseline
```

The task writes one `item` snapshot per complete existing `sync_item`, sets its
local snapshot baseline so subsequent syncs emit only later changes, and writes
membership mappings whose confidence is `high` or `medium`. The JSON summary
reports item counts by service, mapping counts by confidence, and skipped
incomplete records. `low` mappings are counted but intentionally withheld for
manual cleanup or later Web-side review.

Snapshots carry `provenance.detected_by: backfill` and `backfilled_at`; no
historical observations or sync-run records are created. The task does not call
external source systems. It is safe to rerun: source timestamps and unique
outbox idempotency keys retain the original baseline rows.

After reviewing the dry-run output and the pending outbox rows, enable the
TaskBridge Web publication setting and run the normal publisher:

```sh
bundle exec rake task_bridge:outbox:publish
```
