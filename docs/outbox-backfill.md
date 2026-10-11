# Outbox baseline backfill

Before enabling `task_bridge.web.enabled`, seed TaskBridge Web's current-state
baseline from the existing local sync data:

```sh
bundle exec rake task_bridge:backfill_outbox DRY_RUN=true
bundle exec rake task_bridge:backfill_outbox
bundle exec rake task_bridge:outbox:publish_dry_run
```

The first command makes no database or network changes and prints JSON counts
by source service, mapping confidence, and skipped incomplete records. The
second command is idempotent: baseline rows use each record's existing
first-observed timestamp for their deterministic idempotency key. It writes no
source provider data and emits no `sync_run` or `snapshot_seen` rows.

The backfill emits one `item` current-state snapshot per complete sync item,
marks it with `provenance.detected_by: backfill` and `backfilled_at`, and seeds
the local diff baseline. Mapping memberships with high confidence are emitted
as `confirmed` and medium confidence as `inferred`. Low-confidence,
title-derived or otherwise tentative mappings are withheld from publication and
are visible in the dry-run `by_confidence` and `skipped` counts for manual
review.

After reviewing the dry-run output and rendered outbox batches, enable the Web
publication configuration and run the normal publisher.
