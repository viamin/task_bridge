# TaskBridge Web baseline backfill

Run this once after the observation-pipeline migrations are deployed and before
enabling TaskBridge Web publication. It only writes TaskBridge's local
provenance columns and outbox; it never contacts or mutates an external source.

Preview the work first:

```sh
bundle exec rake task_bridge:backfill_outbox_baseline DRY_RUN=1
```

The JSON summary is grouped by source service and includes created/existing
snapshots, mapping confidence counts, withheld low-confidence mappings, and
incomplete records. Review withheld mappings separately; they are deliberately
not sent to TaskBridge Web.

Then seed the local outbox:

```sh
bundle exec rake task_bridge:backfill_outbox_baseline
```

The task first fills missing source and collection provenance, then enqueues one
current-state `item` snapshot per known item. Each payload is marked with
`provenance.detected_by: backfill`, `initial_observation: true`, and
`backfilled_at`; it does not create synthetic `snapshot_seen` observations or
sync-run rows. High-confidence mappings publish as `confirmed`; medium
title-derived mappings publish as `inferred`; low/tentative mappings are held
back. The outbox idempotency keys use each record's stable observation time, so
rerunning after interruption is safe and preserves any delivery state.
