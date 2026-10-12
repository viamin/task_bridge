# TaskBridge Web Baseline Backfill

Before enabling TaskBridge Web publication for an existing installation, seed
the local outbox with the current synchronized state:

```sh
bundle exec rake task_bridge:backfill_observation_baseline
```

Preview the work without changing the database:

```sh
DRY_RUN=1 bundle exec rake task_bridge:backfill_observation_baseline
```

The task prints JSON counts for item snapshots by service, mappings by
confidence, and skipped records. It first fills local source and mapping
provenance, then queues one `item` baseline snapshot per complete source item.
Each snapshot has `provenance.detected_by: "backfill"`, `baseline: true`, and a
`backfilled_at` timestamp. It does not create `snapshot_seen` observations or
sync-run rows, so it cannot be interpreted as historical change activity.

Only high-confidence mappings (`confirmed`) and medium-confidence mappings
(`inferred`) are queued. Low-confidence/title-derived mappings are withheld;
their count is reported as `skipped.low_confidence_mappings` for manual cleanup
or review. The task makes no provider API calls and never mutates an external
source system.

It is safe to rerun: item and mapping rows use deterministic idempotency keys.
After reviewing the dry run and the pending local outbox, enable normal
publication and run `bundle exec rake task_bridge:outbox:publish`.
