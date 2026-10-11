# TaskBridge Web baseline backfill

Before enabling TaskBridge Web publication for an existing installation, seed the local outbox with the current synchronized state:

```sh
bundle exec rails task_bridge:backfill_outbox DRY_RUN=1
bundle exec rails task_bridge:backfill_outbox
bundle exec rails task_bridge:outbox:publish_dry_run
```

The dry run makes no writes and prints prospective item counts by service, mapping counts by confidence, and incomplete or withheld records. The write run is safe to repeat: item and mapping idempotency keys use the stable original observation timestamps, and existing outbox rows are reused.

The backfill never calls external services. It fills local provenance from existing `sync_items`, creates one `item` current-state snapshot per complete item, and establishes each item's local diff baseline. These rows carry `provenance.detected_by: "backfill"` and `backfilled_at`; they are not historical `snapshot_seen` observations. It does not create sync-run rows.

Only high-confidence (`confirmed`) and medium-confidence (`inferred`) memberships enter the outbox. Low-confidence/title-derived memberships are withheld and counted in the dry-run summary for manual cleanup or later review. After reviewing the dry-run batch, enable the normal outbox publisher through the deployment's TaskBridge Web configuration.
