# Backfilling TaskBridge Web observations

Before enabling TaskBridge Web publication for an existing installation, seed
the local outbox with the current synchronized state:

```sh
bundle exec rake task_bridge:backfill_observations
```

Preview the work without writing local provenance, snapshots, mappings, or
outbox rows:

```sh
DRY_RUN=true bundle exec rake task_bridge:backfill_observations
```

The summary groups item snapshots by service, mapping memberships by local
confidence, and skipped records by reason. The task is safe to rerun: source
identities and mapping provenance are filled only where absent, and outbox
idempotency keys preserve one baseline row per source item or membership.

Baseline item rows carry `provenance.detected_by: backfill` and a
`backfilled_at` timestamp. They describe current state only; the task creates
no `snapshot_seen`, change, deletion, or sync-run observations. It never
contacts or mutates an external source system.

Mappings with high confidence are published as `confirmed`; medium confidence
is published as `inferred`. Low-confidence/title-derived and manual mappings
are withheld, and remain visible in the dry-run summary for manual cleanup or
Web-side review. Once the backfill completes, enable normal outbox publication
with the deployment's configured TaskBridge Web publication setting.
