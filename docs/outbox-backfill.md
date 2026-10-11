# Outbox baseline backfill

Run the baseline backfill once before enabling TaskBridge Web publication for
an installation that already has synchronized items:

```sh
bundle exec rake task_bridge:outbox:backfill DRY_RUN=1
bundle exec rake task_bridge:outbox:backfill
bundle exec rake task_bridge:outbox:publish
```

The dry run does not update local provenance or create outbox rows. Its JSON
summary lists item candidates by service, publishable mapping memberships by
confidence, withheld low-confidence memberships, and incomplete records skipped
for lack of an external ID.

The write run first fills missing local source and mapping provenance, then
adds one baseline `item` snapshot for each complete synchronized item. The
snapshot is marked `provenance.detected_by: backfill`, `baseline: true`, and
with a `backfilled_at` timestamp. It does not create `snapshot_seen`, change,
deletion, or sync-run observations, so it cannot be interpreted as historical
activity.

Mapping memberships with high confidence are published as `confirmed`; medium
confidence memberships are `inferred`. Low-confidence/title-derived mappings
are deliberately withheld and remain visible in the dry-run report for manual
cleanup or later review. The task never contacts external source systems.

Both source records and memberships use deterministic idempotency keys, so it
is safe to rerun this task. Single-instance services use the stable
`<service_type>:default` service-instance token in those keys.
