# TaskBridge Web baseline backfill

Before enabling `task_bridge.web.enabled`, seed the local outbox from the
existing synchronized state:

```sh
bundle exec rake task_bridge:backfill_outbox DRY_RUN=true
bundle exec rake task_bridge:backfill_outbox
```

The dry run only prints a JSON count summary by service and mapping confidence;
it does not update records or enqueue rows. The real run first fills missing
source provenance and mapping metadata, then writes one baseline `item` snapshot
per complete `sync_item` and publishable mapping rows. It never contacts or
modifies an external source system.

Baseline snapshots carry `baseline: true` and `provenance.detected_by: backfill`
with `backfilled_at`; they are current state, not historical change events. No
`snapshot_seen` observation or `sync_run` rows are created. Re-running the task
is safe because the stable observed timestamp is part of each outbox idempotency
key.

Mappings with high confidence are sent as `confirmed`, medium confidence as
`inferred`, and low confidence mappings are withheld. The dry-run summary calls
out those withheld memberships for manual cleanup or review before publication.
After the real run, inspect the pending outbox with
`bundle exec rake task_bridge:outbox:publish_dry_run`; only then enable Web
publication and run the normal publisher task.
