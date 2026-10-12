# Backfilling TaskBridge Web observations

Before enabling TaskBridge Web publication for an existing deployment, seed
the local outbox with current-state snapshots:

```sh
bundle exec rake task_bridge:backfill_observations DRY_RUN=1
bundle exec rake task_bridge:backfill_observations
bundle exec rake task_bridge:outbox:publish_dry_run
```

The first command makes no writes and prints item counts by service, mapping
counts by confidence and service, and incomplete/skipped records. The second
is idempotent: it fills source and mapping provenance where it is absent,
creates one baseline `item` snapshot per known source item, and records the
snapshot as the local diff baseline. It never contacts or mutates an external
source system. It does not create `snapshot_seen` observations or `sync_run`
rows, so these records are explicitly initial state, not claimed history.

Backfilled snapshots carry `provenance.detected_by: backfill`,
`initial_observation: true`, and `backfilled_at`. Mapping rows are emitted only
for high (`confirmed`) and medium (`inferred`) confidence memberships. Low
(`tentative`) mappings are withheld; their count remains visible in dry-run
output for manual cleanup or TaskBridge Web review.

Review the dry-run output before running the write command, then use the
normal outbox publisher once publication has been enabled.
