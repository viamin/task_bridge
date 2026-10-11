# Backfilling Baseline Snapshots, Mappings, and Observations

- Issue: #222
- Parent: #214
- Depends on: #216, #217, #218 (normalized snapshots, sync item
  provenance, local observation outbox)
- Contract: RDR #215 (`docs/rdr-215-taskbridge-observation-publication-contract.md`),
  "Migration and Backfill Implications"

`sync_items` and `sync_collections` already represent real synchronized
work. TaskBridge Web needs a safe baseline from that existing data so it
starts from known current state and only treats *later* diffs as change
history. This backfill is local and write-only: it enqueues rows into the
TaskBridge outbox (`OutboxEntry`); it never calls out to a provider API and
never mutates `sync_items`/`sync_collections`.

## What it emits

| Producer | Record kind | Source |
|---|---|---|
| `SyncBackfill::BaselineSnapshots` | `item` | one row per existing `sync_items` row with an identity and an external ID |
| `SyncBackfill::BaselineMappings` | `mapping` | one row per `SyncCollection` member, for collections with `confirmed` or `inferred` mapping confidence only |

It does **not** emit `observation` rows (no `snapshot_seen`) or `sync_run`
rows:

- an `observation` row would read as a just-happened change, which
  existing data is not (clarified for #222: item snapshot only);
- `sync_service_states` keeps only the latest attempt per service, with no
  reliable per-run start/end timestamps, and the RDR requires reliable
  timestamps for a published sync-run summary.

Every backfilled `item` row carries `provenance.detected_by: "backfill"`
and a `provenance.backfilled_at` timestamp, so TaskBridge Web can tell a
baseline row from a live one even though both use the same `item` record
kind and contract version.

## Low-confidence mappings are withheld, not published as tentative

`SyncCollection#mapping_confidence` holds `high`, `medium`, or `low`.
`Outbox::MappingEmitter` translates that to the publication contract's
`mapping_confidence` (`confirmed`/`inferred`/`tentative`): `high ->
confirmed`, `medium -> inferred`, `low -> tentative`.

RDR #215 left open whether backfill should publish `tentative` rows or
withhold them (see its "Open Questions"). This was resolved for #222 in
favor of the RDR's stated default: `SyncBackfill::BaselineMappings`
enqueues only `confirmed` and `inferred` mapping rows. `low`-confidence
(`tentative`) memberships are **not** enqueued — they are withheld from
publication and only listed, by `sync_collection_id`, in this backfill's
own summary output, for manual cleanup or Web-side review.

## `service_instance` default for single-instance services

A service with no configured instance (OmniFocus, Reminders, and any
other adapter without an `Instance:name` suffix) has no
`source_service_instance`. Because `service_instance` is embedded in
every idempotency key and must stay stable forever, it needs a permanent
default rather than a bare `service_type`. `Outbox::SourceIdentity` uses
the token `<service_type>:default` (for example `omnifocus:default`),
matching the RDR's own examples (`asana:workspace-12345:default`). The
live pipeline (`Outbox::ObservationEmitter`, `Outbox::MappingEmitter`,
`Github::ActivityEmitter`) and this backfill share the same helper, so
backfilled and live rows for the same item resolve to the same identity.

## Idempotency

Re-running the backfill is safe:

- `OutboxEntry.enqueue` is `create_or_find_by(idempotency_key:)` — a
  colliding key returns the existing row untouched rather than duplicating
  it.
- `SyncBackfill::BaselineSnapshots` derives each `item` row's
  `observed_at` from the item's own `last_observed_at` (not the time the
  backfill runs), so the idempotency key is stable across runs.
- `SyncBackfill::BaselineMappings` derives each `mapping` row's
  `observed_at` from the collection's `mapping_last_observed_at`, for the
  same reason.

Running the backfill before `task_bridge:backfill_sync_provenance` has
populated `source_service_name`/`mapping_method` leaves those rows
skipped (counted, not silently dropped) rather than publishing incomplete
identity.

## How to run it

The backfill only ever writes to the local outbox; it never sends
anything over HTTP. Run it with TaskBridge Web publication left disabled
(`task_bridge.web.enabled: false` in `config/settings.yml`, the default)
so you can review what would be sent before any of it leaves TaskBridge:

```bash
# 1. Make sure existing identity/provenance is backfilled first (#216-#218)
bundle exec rake task_bridge:backfill_sync_provenance

# 2. Preview counts by service, confidence, and skipped/incomplete
#    records — writes nothing
bundle exec rake task_bridge:backfill_baseline_observations:dry_run

# 3. Enqueue the baseline item and mapping rows into the local outbox
bundle exec rake task_bridge:backfill_baseline_observations:run

# 4. Preview what would be published, still without sending anything
bundle exec rake task_bridge:outbox:publish_dry_run

# 5. Only once the preview looks right, enable publication
#    (task_bridge.web.enabled: true) and publish
bundle exec rake task_bridge:outbox:publish
```

Steps 2 and 3 can be re-run safely at any time (see Idempotency); re-run
step 2 after step 3 to confirm `skipped`/`withheld`/`incomplete` have
dropped to the records you expect to leave for manual review.
