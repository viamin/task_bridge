# Baseline backfill before enabling TaskBridge Web publication

- Issue: #222
- Depends on: #215 (RDR), #216, #217, #218, #219, #220

The observation pipeline publishes rows into a local outbox; a separate
publisher delivers them to TaskBridge Web (`POST
/api/task_bridge/v1/ingestion/batches`, RDR #215). Existing
`sync_items` and `sync_collections` represent real synchronized work
that pre-dates the pipeline. TaskBridge Web should not start from an
empty seed: it needs to know the current state of every known source
item and every known `SyncCollection` membership so later observations
can be treated as change history instead of an audit replay.

The baseline backfill — exposed as the
`task_bridge:backfill_baseline_observations` rake task — emits that
initial state into the outbox idempotently. It does not mutate any
external source system; it only writes to the local outbox. Once
publication (`task_bridge:outbox:publish`) is enabled, TaskBridge Web
ingests these baseline rows as its seed.

## What the backfill writes

For every persisted `Base::SyncItem`:

- one `item` row carrying the current normalized snapshot, marked as a
  baseline via `provenance.detected_by: "backfill"` and a
  `provenance.backfilled_at` timestamp;
- one `OutboxEntry` is sufficient — no `snapshot_seen` observation row is
  emitted alongside it (clarified under #222: the item row already
  represents the current state, so a paired observation would duplicate
  the fact);
- the item's `sync_items.last_snapshot` is advanced to the
  backfilled snapshot so the next live observation emission (#219)
  diffs against the backfilled current state instead of re-publishing
  a `snapshot_seen`.

For every persisted `SyncCollection` membership:

- one `mapping` row per eligible member, with `mapping_confidence`
  translated from TaskBridge's internal vocabulary to the contract
  enum (`high` → `confirmed`, `medium` → `inferred`);
- memberships at `mapping_confidence: low` (including collections whose
  provenance was never populated by `task_bridge:backfill_sync_provenance`)
  are withheld from the outbox so TaskBridge Web never sees a
  low-confidence linkage by default. They remain visible in the
  dry-run summary counts for later manual cleanup.

`sync_run` rows are intentionally not emitted: `sync_service_states`
carries no reliable per-run start/end timestamps, and the contract
requires reliable timestamps for backfilled sync-run summaries. Real
sync runs will publish `sync_run` rows going forward.

## Idempotency

- `idempotency_key` is derived from each source item's stable
  observation timestamp (`last_modified || updated_at || created_at`),
  so re-running produces identical keys.
- The unique index on `outbox_entries.idempotency_key` dedupes reruns.
- The dry-run summary (`DRY_RUN=1`) renders the same shape of counts
  the live run would produce, so a preview always equals a future live
  run on identical input.

## How to run it

Run the backfill before enabling publication:

```bash
# Preview what would be written. Safe to run repeatedly.
DRY_RUN=1 bundle exec rake task_bridge:backfill_baseline_observations

# Write the baseline rows to the outbox. Idempotent; rerun any time.
bundle exec rake task_bridge:backfill_baseline_observations
```

The summary prints counts by service, by mapping confidence, and the
number of withheld low-confidence memberships plus skipped/incomplete
records. Review these counts before pointing the publisher at a real
TaskBridge Web deployment.

After the backfill completes, enable publication in
`config/settings.yml` (or via the `TASK_BRIDGE_WEB_ENABLED=1` Chamber
override):

```bash
bundle exec rake task_bridge:outbox:publish
```

The publisher picks up the pending rows and begins pushing them to
TaskBridge Web. Delivered rows are pruned by
`task_bridge:outbox:prune` after the configured retention window.

## Things to know

- **Default service instance**: items without an explicit instance
  suffix (`Omnifocus`, `Reminders`, un-prefixed `Asana`, etc.) get
  `<service_type>:default` so `service_instance` is always populated
  on every emitted row. The `:default` token is permanent — it is
  embedded in idempotency keys (RDR #215 Identity Model). The live
  pipeline (#219-#221) uses the same default so backfilled and live
  rows share identities. See `app/services/outbox/source_identity.rb`.
- **Dry run**: `--pretend` mode (or `DRY_RUN=1`) writes no outbox rows
  and never advances `last_snapshot`, so the existing source-of-truth
  state stays intact while operators preview the seed.
- **External systems**: the backfill only writes to TaskBridge's local
  outbox. It makes no API calls back to OmniFocus, Asana, GitHub,
  Google Tasks, or any other provider, so it is safe to run with
  provider credentials stale or unavailable.
- **Out of scope**: the backfill writes baseline observations for the
  `task` entity type only. New entity kinds require a new contract
  version (RDR #215 "Minimum Normalized Item Snapshot Schema").
