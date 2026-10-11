# Outbox Baseline Backfill

Issue #222 seeds TaskBridge Web with the current state already synchronized by
TaskBridge. It does not fabricate source history: every existing item creates
one `item` snapshot whose provenance is `detected_by: backfill` and whose
baseline metadata includes `backfilled_at`. It deliberately creates no
`snapshot_seen` observations and no `sync_run` rows.

Run a preview first. It does not write TaskBridge records or contact a source
system:

```sh
DRY_RUN=true bundle exec rake task_bridge:backfill_outbox_baseline
```

The preview reports candidate item snapshots by source service, memberships by
confidence, and skipped/incomplete records. Low-confidence (`low` / tentative)
memberships are counted as withheld for manual cleanup or Web-side review; they
are not enqueued. High-confidence mappings publish as `confirmed` and
title-derived medium-confidence mappings publish as `inferred`.

After reviewing that summary, seed the local outbox:

```sh
bundle exec rake task_bridge:backfill_outbox_baseline
```

The task first fills missing local source provenance and mapping metadata, then
uses the stable `last_observed_at` / mapping observation timestamps to form
idempotency keys. It can therefore be run repeatedly without changing existing
outbox rows. It never calls external source services. Keep TaskBridge Web
publication disabled until the resulting pending outbox rows have been reviewed;
enable the existing `task_bridge.web.enabled` setting only when ready to publish.
