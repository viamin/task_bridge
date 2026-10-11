# Observation backfill

Before enabling TaskBridge Web publication, seed the local outbox from existing
TaskBridge sync data. The backfill writes only local provenance metadata and
outbox rows; it never calls or changes an external source system.

First inspect the planned work. This does not write provenance, snapshots, or
outbox rows:

```sh
DRY_RUN=1 bundle exec rake task_bridge:backfill_observation_baseline
```

The one-line JSON report groups item snapshots, mapping memberships,
low-confidence memberships withheld from publication, and skipped/incomplete
records by service and confidence/reason. Review the withheld low-confidence
(`tentative`) mappings before resolving them manually.

Then perform the local backfill:

```sh
bundle exec rake task_bridge:backfill_observation_baseline
```

It first fills missing source provenance and collection mapping metadata, then
enqueues one baseline `item` snapshot per known source item and mapping rows for
only high (`confirmed`) and medium (`inferred`) confidence memberships. It does
not enqueue `snapshot_seen` observations or synthetic sync-run rows, so the
baseline is not represented as historical activity. Snapshot payloads are marked
with `provenance.detected_by: "backfill"`, `provenance.baseline: true`, and a
`backfilled_at` timestamp.

The operation is safe to rerun: source/mapping fields are only filled when
missing and outbox idempotency keys deduplicate the deterministic baseline rows.
Single-instance services use the permanent `<service_type>:default` identity.
After reviewing the dry-run report and confirming the pending outbox rows, enable
TaskBridge Web publication through the existing `task_bridge.web.enabled`
configuration.
