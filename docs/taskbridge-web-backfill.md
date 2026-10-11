# TaskBridge Web baseline backfill

Run the baseline backfill once before enabling TaskBridge Web publication. It creates local outbox rows only; it never calls or mutates an external source system.

Preview the effect first. This does not update provenance, snapshots, mappings, or outbox rows:

```sh
DRY_RUN=1 bundle exec rake task_bridge:backfill_observation_baseline
```

The JSON summary groups item and mapping rows by service, mapping collections by confidence, and incomplete or withheld records by skip reason. Low-confidence (`low` / `tentative`) memberships are deliberately withheld and counted as `low_confidence_mapping`; resolve those mappings locally before a later backfill if they should be published.

When the preview is acceptable, run:

```sh
bundle exec rake task_bridge:backfill_observation_baseline
```

The task first fills missing source and mapping provenance, then queues one baseline `item` snapshot for every synchronized item and a `mapping` row for each high- or medium-confidence membership. Item payloads are explicitly marked `provenance.detected_by: backfill`, with `baseline: true` and `backfilled_at`; no historical observation or sync-run rows are invented. It also stores a local snapshot baseline, preventing the next live sync from treating the known current state as a new change.

It is safe to rerun: source facts are only filled when absent, existing outbox idempotency keys are reused, and an existing local snapshot is not replaced. After reviewing the pending outbox with `bundle exec rake task_bridge:outbox:publish_dry_run`, enable `task_bridge.web.enabled` and publish normally.
