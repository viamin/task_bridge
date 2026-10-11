# Outbox baseline backfill

Run this once after deploying the observation outbox and before enabling TaskBridge Web publication. It only reads existing local sync data and writes local provenance, snapshots, mapping metadata, and outbox rows; it never contacts or mutates an external source.

Preview first:

```sh
DRY_RUN=true bundle exec rake task_bridge:backfill_outbox
```

The JSON summary groups item snapshots by service, mapping memberships by confidence, withheld low-confidence memberships, and incomplete records that were skipped. Review withheld records before resolving their mappings manually.

Then seed the outbox:

```sh
bundle exec rake task_bridge:backfill_outbox
```

The task is safe to rerun. Snapshot and mapping rows use deterministic idempotency keys, and it stores the baseline snapshot locally so later source refreshes produce diffs rather than fabricated historical events. Baseline item rows carry `provenance.detected_by: "backfill"`, `baseline: true`, and `backfilled_at`; they do not create `snapshot_seen` observations or synthetic `sync_run` rows.

Mappings with high and medium local confidence are published as `confirmed` and `inferred`. Low-confidence (`tentative`) mappings are withheld and remain visible in dry-run output for manual cleanup or review.
