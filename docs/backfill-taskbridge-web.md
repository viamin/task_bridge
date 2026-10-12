# Backfilling TaskBridge Web baseline state

Before enabling `task_bridge.web.enabled`, seed the local outbox from the synchronized data already in TaskBridge. The backfill is local-only: it does not call or mutate OmniFocus, Asana, GitHub, Google Tasks, or any other source.

Preview the work first:

```sh
DRY_RUN=1 bundle exec rake task_bridge:backfill_observations
```

The preview reports item and publishable-mapping counts by service, mapping counts by confidence, and skipped records. It derives missing provenance for reporting but does not write anything.

After reviewing the output, enqueue the baseline:

```sh
bundle exec rake task_bridge:backfill_observations
```

This first fills missing source provenance and collection mapping metadata, then creates one `item` outbox snapshot per existing item. Snapshot payloads carry `provenance.detected_by: "backfill"` and `backfilled_at`; they do not create `snapshot_seen`, change, deletion, or sync-run observations. Deterministic keys use the existing observed timestamp, so rerunning is safe.

Mapping rows are emitted only for `high`/`confirmed` and `medium`/`inferred` evidence. `low`/`tentative` title-less/manual mappings are intentionally withheld and reported in the dry-run summary for manual cleanup or later Web-side review. No backfilled `sync_run` rows are produced because legacy service-state data cannot provide reliable per-run timestamps.

Only enable TaskBridge Web publication after the baseline rows have been successfully delivered. Single-instance services use the permanent `<service_type>:default` source instance identity, matching new live observations.
